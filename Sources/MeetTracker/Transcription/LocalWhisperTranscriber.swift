import Foundation

struct LocalTranscriptionEnvironment: Equatable {
    let pythonURL: URL

    static func discover() -> LocalTranscriptionEnvironment? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let configured = ProcessInfo.processInfo.environment[
            "MEETTRACKER_TRANSKRIPTOR_PYTHON"
        ] {
            candidates.append(URL(fileURLWithPath: configured))
        }

        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceRepository = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            sourceRepository
                .deletingLastPathComponent()
                .appendingPathComponent("transkriptor/venv/bin/python")
        )

        let bundleRepository = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            bundleRepository
                .deletingLastPathComponent()
                .appendingPathComponent("transkriptor/venv/bin/python")
        )

        guard let python = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            return nil
        }
        return LocalTranscriptionEnvironment(pythonURL: python)
    }

    static var hasCachedHuggingFaceToken: Bool {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface")
        return ["token", "stored_tokens"].contains {
            FileManager.default.fileExists(
                atPath: cache.appendingPathComponent($0).path
            )
        }
    }

    static func isWhisperModelCached(_ model: WhisperModelOption) -> Bool {
        let modelDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(
                "models--Systran--faster-whisper-\(model.rawValue)"
            )
        return FileManager.default.fileExists(atPath: modelDirectory.path)
    }
}

final class LocalWhisperTranscriber: AudioTranscribing {
    enum LocalError: LocalizedError {
        case bridgeUnavailable
        case processFailed(String)
        case invalidResult

        var errorDescription: String? {
            switch self {
            case .bridgeUnavailable:
                return "No se encontró el puente local de Transkriptor."
            case .processFailed(let message):
                return "El transcriptor local falló: \(message)"
            case .invalidResult:
                return "El transcriptor local devolvió un resultado inválido."
            }
        }
    }

    let providerName: String
    private let environment: LocalTranscriptionEnvironment
    private let diarize: Bool
    private let huggingFaceToken: String?
    private let model: String
    private let numberOfSpeakers: Int?
    private let language: String?
    private let taskMode: WhisperTaskMode

    init(
        environment: LocalTranscriptionEnvironment,
        diarize: Bool,
        huggingFaceToken: String?,
        numberOfSpeakers: Int? = nil,
        model: String = "small",
        language: String? = "es",
        taskMode: WhisperTaskMode = .transcribe
    ) {
        self.environment = environment
        self.diarize = diarize
        self.huggingFaceToken = huggingFaceToken
        self.numberOfSpeakers = numberOfSpeakers
        self.model = model
        self.language = language
        self.taskMode = taskMode
        let operation = taskMode == .translate ? " · traducción al inglés" : ""
        self.providerName = (
            diarize ? "Whisper local + pyannote" : "Whisper local"
        ) + operation
    }

    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws -> AudioTranscription {
        guard let bridgeURL = Bundle.module.url(
            forResource: "transcribe_bridge",
            withExtension: "py",
            subdirectory: "Resources"
        ) else {
            throw LocalError.bridgeUnavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meettracker-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(
                at: outputURL.appendingPathExtension("partial")
            )
        }

        let process = Process()
        process.executableURL = environment.pythonURL
        var arguments = [
            bridgeURL.path,
            url.path,
            "--output", outputURL.path,
            "--model", model,
            "--task", taskMode.rawValue
        ] + (diarize ? ["--diarize"] : [])
        if let language {
            arguments += ["--language", language]
        }
        if let numberOfSpeakers, numberOfSpeakers > 0 {
            arguments += ["--num-speakers", String(numberOfSpeakers)]
        }
        process.arguments = arguments

        var processEnvironment = ProcessInfo.processInfo.environment
        if let token = huggingFaceToken, !token.isEmpty {
            processEnvironment["HF_TOKEN"] = token
        }
        processEnvironment["MPLCONFIGDIR"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("meettracker-matplotlib")
            .path
        process.environment = processEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = ProgressOutputCollector(progress: progress)
        let stderrCollector = TextOutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.consume(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrCollector.consume(data)
            }
        }

        let processBox = CancellableProcessBox()
        let completionGate = CompletionGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let finish: @Sendable (Process) -> Void = { completed in
                    completionGate.runOnce {
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        collector.finish()
                        let stderrMessage = stderrCollector.text
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        if processBox.wasCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if completed.terminationStatus != 0 {
                            let message = collector.errorMessage
                                ?? stderrMessage.nonEmpty?
                                    .tail(maximumCharacters: 1_200)
                                ?? "código \(completed.terminationStatus)"
                            continuation.resume(
                                throwing: LocalError.processFailed(message)
                            )
                        } else {
                            continuation.resume()
                        }
                    }
                }
                process.terminationHandler = finish

                do {
                    try process.run()
                    // The parent must not retain the writing ends. Otherwise an
                    // EOF read can remain suspended after Python has already died.
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    processBox.set(process)

                    // Polling is a safety net if the termination callback is
                    // delayed. The gate resumes the continuation exactly once.
                    Task.detached {
                        while process.isRunning {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        finish(process)
                    }
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    completionGate.runOnce {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            processBox.cancel()
        }

        guard let data = try? Data(contentsOf: outputURL) else {
            throw LocalError.invalidResult
        }
        return try Self.decodeTranscriptionResponse(data)
    }

    static func decodeTranscriptionResponse(_ data: Data) throws -> AudioTranscription {
        guard let response = try? JSONDecoder().decode(BridgeResponse.self, from: data) else {
            throw LocalError.invalidResult
        }
        return AudioTranscription(
            text: response.text,
            segments: response.segments.map {
                RecognizedAudioSegment(
                    speakerLabel: $0.speaker,
                    startTime: $0.start,
                    endTime: $0.end,
                    text: $0.text
                )
            }
        )
    }

}

private struct BridgeResponse: Decodable {
    struct Segment: Decodable {
        let speaker: String?
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    let text: String
    let segments: [Segment]
}

private struct BridgeEvent: Decodable {
    let kind: String
    let fraction: Double?
    let stage: String?
    let detail: String?
    let message: String?
}

private final class ProgressOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var storedErrorMessage: String?
    private let progress: @Sendable (TranscriberProgress) -> Void

    init(progress: @escaping @Sendable (TranscriberProgress) -> Void) {
        self.progress = progress
    }

    var errorMessage: String? {
        lock.withLock { storedErrorMessage }
    }

    func consume(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var complete: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                complete.append(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
            }
            return complete
        }
        lines.forEach(process)
    }

    func finish() {
        let remaining: Data = lock.withLock {
            let value = buffer
            buffer.removeAll()
            return value
        }
        if !remaining.isEmpty {
            process(remaining)
        }
    }

    private func process(_ data: Data) {
        guard let event = try? JSONDecoder().decode(BridgeEvent.self, from: data) else {
            return
        }
        if event.kind == "error", let message = event.message {
            lock.withLock { storedErrorMessage = message }
        } else if event.kind == "progress",
                  let fraction = event.fraction,
                  let stage = event.stage,
                  let detail = event.detail {
            progress(
                TranscriberProgress(
                    fraction: fraction,
                    stage: stage,
                    detail: detail
                )
            )
        }
    }
}

private final class TextOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var text: String {
        lock.withLock {
            String(data: data, encoding: .utf8) ?? ""
        }
    }

    func consume(_ newData: Data) {
        lock.withLock {
            data.append(newData)
        }
    }
}

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false

    func runOnce(_ operation: () -> Void) {
        let shouldRun = lock.withLock {
            guard !hasRun else { return false }
            hasRun = true
            return true
        }
        if shouldRun {
            operation()
        }
    }
}

private final class CancellableProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func set(_ process: Process) {
        let shouldCancel = lock.withLock {
            self.process = process
            return cancelled
        }
        if shouldCancel, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        let process = lock.withLock {
            cancelled = true
            return self.process
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    func tail(maximumCharacters: Int) -> String {
        count <= maximumCharacters ? self : String(suffix(maximumCharacters))
    }
}

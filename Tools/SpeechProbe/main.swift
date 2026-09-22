import AppKit
import Foundation
import Speech

private struct ProbeSegment: Codable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    let confidence: Float
}

private struct ProbeResult: Codable {
    let text: String
    let locale: String
    let supportsOnDeviceRecognition: Bool
    let elapsedSeconds: TimeInterval
    let segments: [ProbeSegment]
}

private enum ProbeError: LocalizedError {
    case invalidArguments
    case permissionDenied
    case recognizerUnavailable
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Uso: MeetTrackerSpeechProbe <audio> <resultado.json> [locale]"
        case .permissionDenied:
            return "No se autorizó el reconocimiento de voz."
        case .recognizerUnavailable:
            return "Apple Speech no está disponible."
        case .emptyResult:
            return "Apple Speech no devolvió texto."
        }
    }
}

private final class SpeechProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await run()
                NSApp.terminate(nil)
            } catch {
                fputs("SpeechProbe: \(error.localizedDescription)\n", stderr)
                NSApp.terminate(nil)
            }
        }
    }

    private func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            throw ProbeError.invalidArguments
        }

        let audioURL = URL(fileURLWithPath: arguments[1])
        let outputURL = URL(fileURLWithPath: arguments[2])
        let localeIdentifier = arguments.count >= 4 ? arguments[3] : "es-CL"

        guard await requestAuthorization() else {
            throw ProbeError.permissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(
            locale: Locale(identifier: localeIdentifier)
        ), recognizer.isAvailable else {
            throw ProbeError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true

        let startedAt = Date()
        let transcription = try await recognize(using: recognizer, request: request)
        let result = ProbeResult(
            text: transcription.formattedString,
            locale: localeIdentifier,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            segments: transcription.segments.map {
                ProbeSegment(
                    text: $0.substring,
                    start: $0.timestamp,
                    duration: $0.duration,
                    confidence: $0.confidence
                )
            }
        )
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProbeError.emptyResult
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outputURL, options: .atomic)
    }

    private func recognize(
        using recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> SFTranscription {
        try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal, !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: result.bestTranscription)
                } else if let error, !hasResumed {
                    hasResumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            return true
        }
        if status != .notDetermined {
            return false
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization {
                continuation.resume(returning: $0 == .authorized)
            }
        }
    }
}

let application = NSApplication.shared
private let delegate = SpeechProbeDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

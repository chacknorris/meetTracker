import Foundation
import Speech

protocol AudioTranscribing {
    var providerName: String { get }
    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws -> AudioTranscription
}

extension AudioTranscribing {
    func transcribe(
        fileAt url: URL,
        locale: Locale
    ) async throws -> AudioTranscription {
        try await transcribe(fileAt: url, locale: locale, progress: { _ in })
    }
}

final class SpeechTranscriber: AudioTranscribing {
    let providerName = "Apple Speech"

    enum TranscriptionError: LocalizedError {
        case permissionDenied
        case recognizerUnavailable
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "MeetTracker necesita permiso de reconocimiento de voz para transcribir."
            case .recognizerUnavailable:
                return "El reconocimiento de voz no está disponible en este momento."
            case .emptyResult:
                return "No se detectó voz en el archivo de audio."
            }
        }
    }

    func transcribe(
        fileAt url: URL,
        locale: Locale = Locale(identifier: "es-CL"),
        progress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws -> AudioTranscription {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AudioTranscription(text: "", segments: [])
        }
        guard await requestAuthorization() else {
            throw TranscriptionError.permissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }

        progress(
            TranscriberProgress(
                fraction: 0.05,
                stage: "Preparando Apple Speech",
                detail: "Analizando el archivo de audio"
            )
        )
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            var bestPartialResult = AudioTranscription(text: "", segments: [])
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    bestPartialResult = Self.audioTranscription(from: result)
                    let lastEnd = bestPartialResult.segments.last?.endTime ?? 0
                    let fraction = min(0.95, 0.08 + (lastEnd / 3_600))
                    progress(
                        TranscriberProgress(
                            fraction: result.isFinal ? 1 : fraction,
                            stage: "Transcribiendo con Apple Speech",
                            detail: result.isFinal
                                ? "Transcripción terminada"
                                : "\(lastEnd.timelineTimestamp) procesados"
                        )
                    )
                    if result.isFinal, !resumed {
                        resumed = true
                        if bestPartialResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            continuation.resume(throwing: TranscriptionError.emptyResult)
                        } else {
                            continuation.resume(returning: bestPartialResult)
                        }
                        return
                    }
                }
                if let error, !resumed {
                    resumed = true
                    if bestPartialResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: bestPartialResult)
                    }
                }
            }
        }
    }

    private static func audioTranscription(
        from result: SFSpeechRecognitionResult
    ) -> AudioTranscription {
        let transcription = result.bestTranscription
        return AudioTranscription(
            text: transcription.formattedString,
            segments: transcription.segments.map { segment in
                RecognizedAudioSegment(
                    speakerLabel: nil,
                    startTime: segment.timestamp,
                    endTime: segment.timestamp + segment.duration,
                    text: segment.substring
                )
            }
        )
    }

    private func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status != .notDetermined { return false }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus == .authorized)
            }
        }
    }
}

struct TranscriberProgress: Equatable, Sendable {
    var fraction: Double
    var stage: String
    var detail: String

    init(fraction: Double, stage: String, detail: String) {
        self.fraction = min(1, max(0, fraction))
        self.stage = stage
        self.detail = detail
    }
}

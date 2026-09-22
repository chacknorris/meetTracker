import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noDisplayAvailable
        case couldNotStartWriter
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDisplayAvailable:
                return "No se encontró una pantalla disponible para capturar el audio del sistema."
            case .couldNotStartWriter:
                return "No se pudo iniciar el archivo de audio del sistema."
            case .permissionDenied:
                return """
                macOS no reconoció el permiso de MeetTracker para grabar el audio del sistema. \
                Activa MeetTracker en Privacidad y seguridad > Grabación de audio del sistema \
                y pantalla, luego cierra y vuelve a abrir la app.
                """
            }
        }
    }

    private let outputQueue = DispatchQueue(label: "com.meettracker.system-audio")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var hasStartedWriting = false

    func start(outputURL: URL) async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecorderError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw RecorderError.permissionDenied
            }
            throw error
        }
        guard let display = content.displays.first else {
            throw RecorderError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.couldNotStartWriter
        }
        writer.add(input)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)

        self.writer = writer
        self.writerInput = input
        self.stream = stream
        self.hasStartedWriting = false

        try await stream.startCapture()
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil

        await withCheckedContinuation { continuation in
            outputQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.writerInput?.markAsFinished()

                guard self.hasStartedWriting, let writer = self.writer else {
                    self.writer?.cancelWriting()
                    self.reset()
                    continuation.resume()
                    return
                }

                writer.finishWriting { [weak self] in
                    self?.reset()
                    continuation.resume()
                }
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let writer,
              let writerInput else {
            return
        }

        if !hasStartedWriting {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            hasStartedWriting = true
        }

        if writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
        }
    }

    private func reset() {
        writer = nil
        writerInput = nil
        hasStartedWriting = false
    }
}

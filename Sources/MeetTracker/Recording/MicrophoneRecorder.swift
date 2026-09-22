import AVFoundation
import Foundation

final class MicrophoneRecorder: NSObject, AVAudioRecorderDelegate {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case noInputDevice
        case couldNotRecord

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "MeetTracker necesita acceso al micrófono para registrar tu voz."
            case .noInputDevice:
                return "No se encontró un dispositivo de entrada de audio."
            case .couldNotRecord:
                return "No se pudo iniciar la grabación del micrófono."
            }
        }
    }

    private var recorder: AVAudioRecorder?
    private(set) var inputName: String?

    var averagePower: Float {
        guard let recorder, recorder.isRecording else { return -160 }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    func start(outputURL: URL) async throws {
        guard await requestPermission() else {
            throw RecorderError.permissionDenied
        }
        guard let input = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noInputDevice
        }
        inputName = input.localizedName

        let recorder = try AVAudioRecorder(
            url: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecorderError.couldNotRecord
        }
        self.recorder = recorder
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        inputName = nil
    }

    private func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

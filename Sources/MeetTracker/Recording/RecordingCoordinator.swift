import Foundation

final class RecordingCoordinator {
    private let systemRecorder = SystemAudioRecorder()
    private let microphoneRecorder = MicrophoneRecorder()
    private(set) var activeSession: MeetingSession?

    var microphoneName: String? {
        microphoneRecorder.inputName
    }

    var microphonePower: Float {
        microphoneRecorder.averagePower
    }

    func start(session: MeetingSession, repository: MeetingRepository) async throws -> MeetingSession {
        var active = session
        let directory = try repository.createDirectory(for: session)
        let systemURL = directory.appendingPathComponent(session.systemAudioFilename)
        let microphoneURL = directory.appendingPathComponent(session.microphoneAudioFilename)

        do {
            try await microphoneRecorder.start(outputURL: microphoneURL)
            active.microphoneStartOffset = Date().timeIntervalSince(session.startedAt)
            try await systemRecorder.start(outputURL: systemURL)
            active.systemAudioStartOffset = Date().timeIntervalSince(session.startedAt)
            activeSession = active
            return active
        } catch {
            microphoneRecorder.stop()
            await systemRecorder.stop()
            throw error
        }
    }

    func stop() async -> MeetingSession? {
        guard var session = activeSession else { return nil }
        microphoneRecorder.stop()
        await systemRecorder.stop()
        session.endedAt = Date()
        activeSession = nil
        return session
    }
}

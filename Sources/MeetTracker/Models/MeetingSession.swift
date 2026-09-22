import Foundation

struct MeetingSession: Identifiable, Codable, Hashable {
    enum TranscriptionState: String, Codable {
        case notStarted
        case transcribing
        case completed
        case failed
    }

    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var systemAudioFilename: String
    var microphoneAudioFilename: String
    var transcriptFilename: String?
    var transcriptionState: TranscriptionState
    var transcriptionMessage: String?
    var systemTranscriptionMessage: String?
    var microphoneTranscriptionMessage: String?
    var microphoneStartOffset: TimeInterval?
    var systemAudioStartOffset: TimeInterval?
    var conversationFilename: String?
    var transcriptionProvider: String?
    var expectedParticipantCount: Int?
    var microphoneIncludesAllParticipants: Bool?

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    static func new(at date: Date = Date()) -> MeetingSession {
        MeetingSession(
            id: UUID(),
            title: defaultTitle(for: date),
            startedAt: date,
            endedAt: nil,
            systemAudioFilename: "system-audio.m4a",
            microphoneAudioFilename: "microphone.m4a",
            transcriptFilename: nil,
            transcriptionState: .notStarted,
            transcriptionMessage: nil,
            systemTranscriptionMessage: nil,
            microphoneTranscriptionMessage: nil,
            microphoneStartOffset: nil,
            systemAudioStartOffset: nil,
            conversationFilename: nil,
            transcriptionProvider: nil,
            expectedParticipantCount: 2,
            microphoneIncludesAllParticipants: false
        )
    }

    static func defaultTitle(for date: Date) -> String {
        "Reunión \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

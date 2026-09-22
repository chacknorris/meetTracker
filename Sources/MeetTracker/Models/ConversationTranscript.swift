import Foundation

struct ConversationTranscript: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var generatedAt: Date
    var provider: String
    var segments: [ConversationSegment]
    var speakerNames: [String: String]

    init(
        generatedAt: Date = Date(),
        provider: String,
        segments: [ConversationSegment],
        speakerNames: [String: String] = [:]
    ) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.provider = provider
        self.segments = segments.sorted { $0.startTime < $1.startTime }
        self.speakerNames = speakerNames
    }

    var speakerIDs: [String] {
        Array(Set(segments.map(\.speakerID))).sorted { lhs, rhs in
            if lhs == ConversationSpeaker.meID { return true }
            if rhs == ConversationSpeaker.meID { return false }
            return lhs < rhs
        }
    }

    func displayName(for speakerID: String) -> String {
        if let customName = speakerNames[speakerID],
           !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customName
        }
        if speakerID == ConversationSpeaker.meID { return "Yo" }
        if speakerID == ConversationSpeaker.meetingID { return "Reunión" }
        if speakerID.hasPrefix(ConversationSpeaker.remotePrefix) {
            return "Participante \(speakerID.dropFirst(ConversationSpeaker.remotePrefix.count))"
        }
        return speakerID
    }

    func segments(matching query: String) -> [ConversationSegment] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return segments }
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive
        ]
        return segments.filter { segment in
            segment.text.range(of: cleaned, options: options) != nil
                || displayName(for: segment.speakerID)
                    .range(of: cleaned, options: options) != nil
        }
    }

    func markdown(title: String, startedAt: Date) -> String {
        let body = segments.map { segment in
            let timestamp = segment.startTime.timelineTimestamp
            let speaker = displayName(for: segment.speakerID)
            return "**[\(timestamp)] \(speaker):** \(segment.text)"
        }
        .joined(separator: "\n\n")

        return """
        # \(title)

        _\(startedAt.formatted(date: .long, time: .shortened))_

        \(body.isEmpty ? "_No se detectó una conversación._" : body)
        """
    }
}

struct ConversationSegment: Identifiable, Codable, Equatable {
    enum Source: String, Codable {
        case microphone
        case systemAudio
    }

    var id: String
    var speakerID: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var source: Source

    init(
        id: String = UUID().uuidString,
        speakerID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        source: Source
    ) {
        self.id = id
        self.speakerID = speakerID
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
    }
}

enum ConversationSpeaker {
    static let meID = "me"
    static let meetingID = "meeting"
    static let remotePrefix = "remote-"
}

struct RecognizedAudioSegment: Equatable {
    var speakerLabel: String?
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
}

struct AudioTranscription: Equatable {
    var text: String
    var segments: [RecognizedAudioSegment]
}

extension TimeInterval {
    var timelineTimestamp: String {
        let total = max(0, Int(self.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

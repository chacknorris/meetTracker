import Foundation

struct MeetingRepository {
    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
            return
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.rootURL = applicationSupport
            .appendingPathComponent("MeetTracker", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    func createDirectory(for session: MeetingSession) throws -> URL {
        let directory = directoryURL(for: session)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func directoryURL(for session: MeetingSession) -> URL {
        rootURL.appendingPathComponent(session.id.uuidString, isDirectory: true)
    }

    func audioURL(filename: String, for session: MeetingSession) -> URL {
        directoryURL(for: session).appendingPathComponent(filename)
    }

    func transcriptURL(for session: MeetingSession) -> URL {
        directoryURL(for: session).appendingPathComponent("transcript.md")
    }

    func conversationURL(for session: MeetingSession) -> URL {
        directoryURL(for: session).appendingPathComponent("conversation.json")
    }

    func save(_ session: MeetingSession) throws {
        let directory = try createDirectory(for: session)
        let data = try JSONEncoder.meetTracker.encode(session)
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    func loadAll() throws -> [MeetingSession] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }

        let directories = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return directories.compactMap { directory in
            let metadata = directory.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: metadata) else { return nil }
            return try? JSONDecoder.meetTracker.decode(MeetingSession.self, from: data)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func transcript(for session: MeetingSession) -> String? {
        guard let filename = session.transcriptFilename else { return nil }
        let url = directoryURL(for: session).appendingPathComponent(filename)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func saveTranscript(_ transcript: String, for session: MeetingSession) throws {
        let url = transcriptURL(for: session)
        try transcript.write(to: url, atomically: true, encoding: .utf8)
    }

    func conversation(for session: MeetingSession) -> ConversationTranscript? {
        guard session.conversationFilename != nil else { return nil }
        let url = conversationURL(for: session)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ConversationTranscript.self, from: data)
    }

    func saveConversation(_ conversation: ConversationTranscript, for session: MeetingSession) throws {
        let data = try JSONEncoder.meetTracker.encode(conversation)
        try data.write(to: conversationURL(for: session), options: .atomic)
        try saveTranscript(
            conversation.markdown(title: session.title, startedAt: session.startedAt),
            for: session
        )
    }
}

private extension JSONEncoder {
    static var meetTracker: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var meetTracker: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

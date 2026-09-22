import Foundation
import XCTest
@testable import MeetTracker

@MainActor
final class AppModelTimelineTests: XCTestCase {
    func testRoomMeetingKeepsDiarizedMicrophoneSpeakers() async throws {
        UserDefaults.standard.set(false, forKey: "diarizationEnabled")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(rootURL: root)
        var session = MeetingSession.new()
        session.endedAt = Date()
        session.microphoneIncludesAllParticipants = true
        session.expectedParticipantCount = 3
        _ = try repository.createDirectory(for: session)
        try repository.save(session)

        let model = AppModel(
            repository: repository,
            transcriber: RoomMeetingMockTranscriber(),
            localEnvironment: nil
        )
        await model.transcribe(session)

        let updated = try XCTUnwrap(model.sessions.first)
        let conversation = try XCTUnwrap(model.conversation(for: updated))
        XCTAssertEqual(
            conversation.speakerIDs,
            ["remote-SPEAKER_00", "remote-SPEAKER_01"]
        )
        XCTAssertTrue(
            conversation.segments.allSatisfy { $0.source == .microphone }
        )
    }

    func testRenamesMeetingAndRegeneratesTranscriptHeading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(rootURL: root)
        var session = MeetingSession.new()
        session.endedAt = Date()
        session.transcriptionState = .completed
        session.conversationFilename = "conversation.json"
        session.transcriptFilename = "transcript.md"
        try repository.save(session)
        try repository.saveConversation(
            ConversationTranscript(provider: "Mock", segments: []),
            for: session
        )

        let model = AppModel(
            repository: repository,
            transcriber: TimelineMockTranscriber(),
            localEnvironment: nil
        )
        model.rename(session, to: "  Reunión de planificación  ")

        let updated = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(updated.title, "Reunión de planificación")
        XCTAssertEqual(try repository.loadAll().first?.title, updated.title)
        XCTAssertTrue(
            repository.transcript(for: updated)?
                .hasPrefix("# Reunión de planificación") == true
        )
    }

    func testUnifiesFalseRemoteSpeakersForTwoPersonConversation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(rootURL: root)
        var session = MeetingSession.new()
        session.endedAt = Date()
        session.transcriptionState = .completed
        session.conversationFilename = "conversation.json"
        try repository.save(session)
        try repository.saveConversation(
            ConversationTranscript(
                provider: "Whisper local + pyannote",
                segments: [
                    ConversationSegment(
                        speakerID: "remote-SPEAKER_00",
                        startTime: 0,
                        endTime: 2,
                        text: "Hola",
                        source: .systemAudio
                    ),
                    ConversationSegment(
                        speakerID: "remote-SPEAKER_04",
                        startTime: 3,
                        endTime: 4,
                        text: "¿Cómo estás?",
                        source: .systemAudio
                    ),
                    ConversationSegment(
                        speakerID: ConversationSpeaker.meID,
                        startTime: 5,
                        endTime: 6,
                        text: "Bien",
                        source: .microphone
                    )
                ]
            ),
            for: session
        )

        let model = AppModel(
            repository: repository,
            transcriber: TimelineMockTranscriber(),
            localEnvironment: nil
        )
        model.unifyRemoteSpeakersForTwoPersonConversation(session)

        let updated = try XCTUnwrap(model.sessions.first)
        let conversation = try XCTUnwrap(model.conversation(for: updated))
        XCTAssertEqual(
            Set(conversation.segments.map(\.speakerID)),
            [ConversationSpeaker.meID, "remote-SPEAKER_00"]
        )
        XCTAssertEqual(updated.expectedParticipantCount, 2)
    }

    func testRecoversTranscriptionInterruptedByAppClosure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(rootURL: root)
        var session = MeetingSession.new()
        session.endedAt = Date()
        session.transcriptionState = .transcribing
        try repository.save(session)

        let model = AppModel(
            repository: repository,
            transcriber: TimelineMockTranscriber(),
            localEnvironment: nil
        )

        XCTAssertEqual(model.sessions.first?.transcriptionState, .failed)
        XCTAssertTrue(
            model.sessions.first?.transcriptionMessage?.contains("cerró") == true
        )
        XCTAssertEqual(
            try repository.loadAll().first?.transcriptionState,
            .failed
        )
    }

    func testBuildsChronologicalConversationFromBothTracks() async throws {
        UserDefaults.standard.set(false, forKey: "diarizationEnabled")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(rootURL: root)
        var session = MeetingSession.new(at: Date(timeIntervalSince1970: 1_000))
        session.endedAt = Date(timeIntervalSince1970: 1_100)
        session.microphoneStartOffset = 0.2
        session.systemAudioStartOffset = 1.5
        _ = try repository.createDirectory(for: session)
        try repository.save(session)

        let model = AppModel(
            repository: repository,
            transcriber: TimelineMockTranscriber(),
            localEnvironment: nil
        )
        await model.transcribe(session)

        let updated = try XCTUnwrap(model.sessions.first)
        let conversation = try XCTUnwrap(model.conversation(for: updated))
        XCTAssertEqual(conversation.segments.map(\.speakerID), [
            ConversationSpeaker.meID,
            ConversationSpeaker.meetingID
        ])
        XCTAssertEqual(conversation.segments.map(\.startTime), [0.7, 3.5])
        XCTAssertEqual(updated.conversationFilename, "conversation.json")
    }
}

private final class TimelineMockTranscriber: AudioTranscribing {
    let providerName = "Mock"

    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws -> AudioTranscription {
        progress(
            TranscriberProgress(
                fraction: 1,
                stage: "Mock",
                detail: "Listo"
            )
        )
        if url.lastPathComponent == "microphone.m4a" {
            return AudioTranscription(
                text: "Mi respuesta",
                segments: [
                    RecognizedAudioSegment(
                        speakerLabel: nil,
                        startTime: 0.5,
                        endTime: 1.2,
                        text: "Mi respuesta"
                    )
                ]
            )
        }
        return AudioTranscription(
            text: "Pregunta remota",
            segments: [
                RecognizedAudioSegment(
                    speakerLabel: nil,
                    startTime: 2,
                    endTime: 3,
                    text: "Pregunta remota"
                )
            ]
        )
    }
}

private final class RoomMeetingMockTranscriber: AudioTranscribing {
    let providerName = "Mock room"

    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws -> AudioTranscription {
        AudioTranscription(
            text: "Primera voz. Segunda voz.",
            segments: [
                RecognizedAudioSegment(
                    speakerLabel: "SPEAKER_00",
                    startTime: 0,
                    endTime: 2,
                    text: "Primera voz."
                ),
                RecognizedAudioSegment(
                    speakerLabel: "SPEAKER_01",
                    startTime: 3,
                    endTime: 5,
                    text: "Segunda voz."
                )
            ]
        )
    }
}

import Foundation
import XCTest
@testable import MeetTracker

final class MeetingRepositoryTests: XCTestCase {
    func testSessionRoundTripAndOrdering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(rootURL: root)

        var older = MeetingSession.new(at: Date(timeIntervalSince1970: 100))
        older.title = "Anterior"
        var newer = MeetingSession.new(at: Date(timeIntervalSince1970: 200))
        newer.title = "Reciente"

        try repository.save(older)
        try repository.save(newer)

        let sessions = try repository.loadAll()
        XCTAssertEqual(sessions.map(\.title), ["Reciente", "Anterior"])
        XCTAssertEqual(sessions.first?.id, newer.id)
    }

    func testTranscriptRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(rootURL: root)
        var session = MeetingSession.new()

        _ = try repository.createDirectory(for: session)
        try repository.saveTranscript("Hola reunión", for: session)
        session.transcriptFilename = "transcript.md"

        XCTAssertEqual(repository.transcript(for: session), "Hola reunión")
    }

    func testLoadsSessionCreatedBeforePerTrackErrorsWereAdded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Reunión anterior",
          "startedAt": "2026-07-27T20:17:49Z",
          "endedAt": "2026-07-27T20:54:06Z",
          "systemAudioFilename": "system-audio.m4a",
          "microphoneAudioFilename": "microphone.m4a",
          "transcriptFilename": "transcript.md",
          "transcriptionState": "completed"
        }
        """
        try legacyJSON.write(
            to: sessionDirectory.appendingPathComponent("session.json"),
            atomically: true,
            encoding: .utf8
        )

        let sessions = try MeetingRepository(rootURL: root).loadAll()
        XCTAssertEqual(sessions.first?.title, "Reunión anterior")
        XCTAssertNil(sessions.first?.microphoneTranscriptionMessage)
    }
}

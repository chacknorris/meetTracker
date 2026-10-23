import Foundation
import XCTest
@testable import MeetTracker

@MainActor
final class MeetingDeletionTests: XCTestCase {
    private var root: URL!
    private var meetings: URL { root.appendingPathComponent("Meetings", isDirectory: true) }
    private var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
    }

    private func repository() -> MeetingRepository {
        let trash = trash
        return MeetingRepository(rootURL: meetings) { directory in
            try FileManager.default.moveItem(
                at: directory,
                to: trash.appendingPathComponent(directory.lastPathComponent)
            )
        }
    }

    private func completedSession(at time: TimeInterval = 100) -> MeetingSession {
        var session = MeetingSession.new(at: Date(timeIntervalSince1970: time))
        session.endedAt = session.startedAt.addingTimeInterval(60)
        return session
    }

    func testMovesEntireMeetingAndPreservesOtherMeeting() throws {
        let repository = repository()
        var target = completedSession(at: 200)
        target.conversationFilename = "conversation.json"
        target.transcriptFilename = "transcript.md"
        let other = completedSession()
        try repository.save(target)
        try repository.save(other)
        try repository.saveConversation(
            ConversationTranscript(provider: "Mock", segments: []), for: target
        )
        for filename in [target.systemAudioFilename, target.microphoneAudioFilename] {
            try Data("test audio".utf8).write(to: repository.audioURL(filename: filename, for: target))
        }
        let model = AppModel(repository: repository, localEnvironment: nil)
        _ = model.conversation(for: target) // Populate the cache before deletion.

        try model.moveToTrash(target)

        XCTAssertEqual(model.sessions.map(\.id), [other.id])
        XCTAssertEqual(model.selection, other.id)
        XCTAssertEqual(try repository.loadAll().map(\.id), [other.id])
        XCTAssertNil(model.conversation(for: target))
        let moved = trash.appendingPathComponent(target.id.uuidString)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: moved.path)),
            ["session.json", "system-audio.m4a", "microphone.m4a", "transcript.md", "conversation.json"]
        )
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("system-audio.m4a")), Data("test audio".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.directoryURL(for: other).path))
    }

    func testDeletesRequestedMeetingWithoutChangingUnrelatedSelection() throws {
        let repository = repository()
        let first = completedSession(at: 200)
        let second = completedSession()
        try repository.save(first)
        try repository.save(second)
        let model = AppModel(repository: repository, localEnvironment: nil)
        model.selection = second.id

        try model.moveToTrash(first)

        XCTAssertEqual(model.selection, second.id)
        XCTAssertEqual(model.sessions.map(\.id), [second.id])
        try model.moveToTrash(second)
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertThrowsError(try model.moveToTrash(second))
    }

    func testTrashFailureKeepsMeetingSelectionAndFiles() throws {
        let repository = MeetingRepository(rootURL: meetings) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        let session = completedSession()
        try repository.save(session)
        let model = AppModel(repository: repository, localEnvironment: nil)

        XCTAssertThrowsError(try model.moveToTrash(session))

        XCTAssertEqual(model.sessions.map(\.id), [session.id])
        XCTAssertEqual(model.selection, session.id)
        XCTAssertEqual(try repository.loadAll().map(\.id), [session.id])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    func testRefusesMismatchedMetadataAndSymbolicLinks() throws {
        let repository = repository()
        let session = completedSession()
        let other = completedSession(at: 200)
        try repository.save(session)
        try repository.save(other)
        let directory = repository.directoryURL(for: session)
        let metadata = directory.appendingPathComponent("session.json")
        let otherMetadata = repository.directoryURL(for: other).appendingPathComponent("session.json")
        try Data(contentsOf: otherMetadata).write(to: metadata)

        XCTAssertThrowsError(try repository.moveToTrash(session))

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: repository.directoryURL(for: other))
        XCTAssertThrowsError(try repository.moveToTrash(session))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherMetadata.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    func testCancellationBlocksDeletionUntilTranscriptionActuallyExits() async throws {
        let repository = repository()
        let session = completedSession()
        try repository.save(session)
        let transcriber = SuspendedDeletionTranscriber()
        let model = AppModel(repository: repository, transcriber: transcriber, localEnvironment: nil)
        model.beginTranscription(session)
        await transcriber.waitUntilStarted()
        XCTAssertFalse(model.canDelete(session))
        XCTAssertThrowsError(try model.moveToTrash(session))

        model.cancelTranscription(session)
        XCTAssertFalse(model.canDelete(session))
        XCTAssertThrowsError(try model.moveToTrash(session))
        await transcriber.finish()
        // Yield to the transcription task's cancellation cleanup.
        for _ in 0..<1_000 where !model.canDelete(session) {
            await Task.yield()
        }
        XCTAssertTrue(model.canDelete(session))
        try model.moveToTrash(session)
        await Task.yield()
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(try repository.loadAll().isEmpty)
    }
}

private actor SuspendedDeletionTranscriber: AudioTranscribing {
    nonisolated let providerName = "Mock"
    private var continuation: CheckedContinuation<AudioTranscription, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TranscriberProgress) -> Void
    ) async throws -> AudioTranscription {
        await withCheckedContinuation {
            continuation = $0
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func finish() {
        continuation?.resume(returning: AudioTranscription(text: "", segments: []))
        continuation = nil
    }
}

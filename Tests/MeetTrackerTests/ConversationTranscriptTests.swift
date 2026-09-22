import AVFoundation
import Foundation
import XCTest
@testable import MeetTracker

final class ConversationTranscriptTests: XCTestCase {
    func testSearchesTranscriptIgnoringCaseAndDiacritics() {
        let transcript = ConversationTranscript(
            provider: "Test",
            segments: [
                ConversationSegment(
                    speakerID: "remote-A",
                    startTime: 0,
                    endTime: 2,
                    text: "Revisaremos la implementación mañana.",
                    source: .systemAudio
                ),
                ConversationSegment(
                    speakerID: ConversationSpeaker.meID,
                    startTime: 3,
                    endTime: 5,
                    text: "De acuerdo.",
                    source: .microphone
                )
            ],
            speakerNames: ["remote-A": "Carolina"]
        )

        XCTAssertEqual(
            transcript.segments(matching: "IMPLEMENTACION").map(\.speakerID),
            ["remote-A"]
        )
        XCTAssertEqual(
            transcript.segments(matching: "carolina").map(\.speakerID),
            ["remote-A"]
        )
        XCTAssertEqual(transcript.segments(matching: "   "), transcript.segments)
    }

    func testOrdersSegmentsAndRendersSpeakerNamesWithTimestamps() {
        let transcript = ConversationTranscript(
            generatedAt: Date(timeIntervalSince1970: 0),
            provider: "Test",
            segments: [
                ConversationSegment(
                    speakerID: ConversationSpeaker.meID,
                    startTime: 75,
                    endTime: 78,
                    text: "Estoy de acuerdo.",
                    source: .microphone
                ),
                ConversationSegment(
                    speakerID: "remote-A",
                    startTime: 12,
                    endTime: 15,
                    text: "Revisemos el presupuesto.",
                    source: .systemAudio
                )
            ],
            speakerNames: ["remote-A": "Carolina"]
        )

        XCTAssertEqual(transcript.segments.map(\.startTime), [12, 75])
        XCTAssertEqual(transcript.displayName(for: "remote-A"), "Carolina")
        let markdown = transcript.markdown(
            title: "Planificación",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(markdown.contains("**[00:12] Carolina:**"))
        XCTAssertTrue(markdown.contains("**[01:15] Yo:**"))
    }

    func testLocalDiarizedResponseKeepsSpeakerAndTiming() throws {
        let data = Data(
            """
            {
              "duration": 12.8,
              "language": "es",
              "text": "Hola. Buen día.",
              "segments": [
                {
                  "start": 0.2,
                  "end": 2.4,
                  "text": "Hola.",
                  "speaker": "SPEAKER_00"
                },
                {
                  "start": 3.0,
                  "end": 4.2,
                  "text": "Buen día.",
                  "speaker": "SPEAKER_01"
                }
              ]
            }
            """.utf8
        )

        let result = try LocalWhisperTranscriber.decodeTranscriptionResponse(data)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].speakerLabel, "SPEAKER_00")
        XCTAssertEqual(result.segments[1].startTime, 3.0)
        XCTAssertEqual(result.segments[1].endTime, 4.2)
    }

    func testConversationRepositoryRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(rootURL: root)
        var session = MeetingSession.new()
        session.conversationFilename = "conversation.json"
        _ = try repository.createDirectory(for: session)

        let conversation = ConversationTranscript(
            provider: "Test",
            segments: [
                ConversationSegment(
                    speakerID: ConversationSpeaker.meID,
                    startTime: 1,
                    endTime: 2,
                    text: "Hola",
                    source: .microphone
                )
            ]
        )
        try repository.saveConversation(conversation, for: session)

        let loaded = repository.conversation(for: session)
        XCTAssertEqual(loaded?.provider, conversation.provider)
        XCTAssertEqual(loaded?.segments, conversation.segments)
        XCTAssertEqual(loaded?.speakerNames, conversation.speakerNames)
        XCTAssertTrue(repository.transcriptURL(for: session).pathExtension == "md")
    }

    func testCreatesTemporaryCompressedAudioCopy() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: sourceURL,
            settings: format.settings
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)
        )
        buffer.frameLength = 48_000
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                channel[index] = Float(sin(Double(index) * 0.03)) * 0.1
            }
        }
        try file?.write(from: buffer)
        file = nil

        let compressed: URL
        do {
            compressed = try await AudioCompressor.compressedCopy(of: sourceURL)
        } catch AudioCompressor.CompressionError.couldNotConfigure {
            throw XCTSkip("El runner de XCTest no expone el codificador AAC de AVFoundation.")
        }
        defer { AudioCompressor.removeTemporaryCopy(at: compressed) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path))
        XCTAssertEqual(compressed.pathExtension, "m4a")
        XCTAssertGreaterThan(
            try compressed.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            0
        )
    }
}

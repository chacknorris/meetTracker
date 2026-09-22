@preconcurrency import AVFoundation
import Foundation

enum AudioCompressor {
    enum CompressionError: LocalizedError {
        case noAudioTrack
        case couldNotConfigure(String)
        case conversionFailed(String)
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "El archivo no contiene una pista de audio."
            case .couldNotConfigure(let component):
                return "No se pudo preparar \(component) para la diarización."
            case .conversionFailed(let message):
                return "No se pudo comprimir el audio: \(message)"
            case .fileTooLarge:
                return "El audio comprimido supera el límite de carga. Divide la reunión en sesiones más cortas."
            }
        }
    }

    static func compressedCopy(of sourceURL: URL) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetTracker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("meeting-audio.m4a")

        do {
            if let ffmpegURL = ffmpegExecutableURL() {
                do {
                    try await transcodeWithFFmpeg(
                        executableURL: ffmpegURL,
                        sourceURL: sourceURL,
                        outputURL: outputURL
                    )
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    try await transcodeWithAVFoundation(
                        sourceURL: sourceURL,
                        outputURL: outputURL
                    )
                }
            } else {
                try await transcodeWithAVFoundation(
                    sourceURL: sourceURL,
                    outputURL: outputURL
                )
            }
            let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
            if (values.fileSize ?? 0) > 24 * 1_024 * 1_024 {
                throw CompressionError.fileTooLarge
            }
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func removeTemporaryCopy(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func ffmpegExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private static func transcodeWithFFmpeg(
        executableURL: URL,
        sourceURL: URL,
        outputURL: URL
    ) async throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", sourceURL.path,
            "-vn",
            "-ac", "1",
            "-ar", "16k",
            "-c:a", "aac",
            "-b:a", "48k",
            "-movflags", "+faststart",
            outputURL.path
        ]
        process.standardError = errorPipe

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { completed in
                if completed.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: CompressionError.conversionFailed(
                            message?.isEmpty == false ? message! : "ffmpeg terminó con error"
                        )
                    )
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func transcodeWithAVFoundation(
        sourceURL: URL,
        outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CompressionError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw CompressionError.couldNotConfigure("el lector de audio")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw CompressionError.couldNotConfigure("el codificador AAC")
        }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw CompressionError.conversionFailed(
                reader.error?.localizedDescription
                    ?? writer.error?.localizedDescription
                    ?? "no se pudo iniciar la conversión"
            )
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.meettracker.audio-compression")
            var sessionStarted = false
            var finishing = false

            writerInput.requestMediaDataWhenReady(on: queue) {
                guard !finishing else { return }
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        if !sessionStarted {
                            writer.startSession(atSourceTime: sample.presentationTimeStamp)
                            sessionStarted = true
                        }
                        if !writerInput.append(sample) {
                            finishing = true
                            reader.cancelReading()
                            writerInput.markAsFinished()
                            writer.cancelWriting()
                            continuation.resume(
                                throwing: CompressionError.conversionFailed(
                                    writer.error?.localizedDescription ?? "no se pudo codificar el audio"
                                )
                            )
                            return
                        }
                    } else {
                        finishing = true
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(
                                throwing: CompressionError.conversionFailed(
                                    reader.error?.localizedDescription ?? "no se pudo leer el audio"
                                )
                            )
                            return
                        }
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(
                                    throwing: CompressionError.conversionFailed(
                                        writer.error?.localizedDescription
                                            ?? "no se pudo finalizar el archivo"
                                    )
                                )
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}

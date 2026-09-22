import Darwin
import Foundation

enum DiagnosticRunner {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--self-test-compression"),
              arguments.indices.contains(flagIndex + 1) else {
            return
        }

        let sourceURL = URL(fileURLWithPath: arguments[flagIndex + 1])
        Task.detached {
            do {
                let outputURL = try await AudioCompressor.compressedCopy(of: sourceURL)
                let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                print("COMPRESSION_OK path=\(outputURL.path) bytes=\(size)")
                AudioCompressor.removeTemporaryCopy(at: outputURL)
                fflush(stdout)
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                print("COMPRESSION_FAILED \(error.localizedDescription)")
                fflush(stdout)
                Darwin.exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}

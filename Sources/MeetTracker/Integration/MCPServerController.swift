import AppKit
import Foundation

@MainActor
final class MCPServerController: NSObject, ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var title: String {
            switch self {
            case .stopped:
                return "Desactivado"
            case .starting:
                return "Iniciando…"
            case .running:
                return "Disponible"
            case .failed:
                return "No disponible"
            }
        }

        var systemImage: String {
            switch self {
            case .stopped:
                return "stop.circle"
            case .starting:
                return "clock.arrow.circlepath"
            case .running:
                return "checkmark.circle.fill"
            case .failed:
                return "exclamationmark.triangle.fill"
            }
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var port: Int
    @Published private(set) var state: State = .stopped
    @Published private(set) var logMessage = ""

    var endpoint: String {
        "http://127.0.0.1:\(port)/mcp"
    }

    private let defaults: UserDefaults
    private var process: Process?
    private var generation = 0

    private static let enabledKey = "mcpServerEnabled"
    private static let portKey = "mcpServerPort"
    private static let defaultPort = 3210

    init(defaults: UserDefaults = .standard, automaticallyStart: Bool = true) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        let savedPort = defaults.integer(forKey: Self.portKey)
        self.port = Self.validPort(savedPort) ?? Self.defaultPort
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        if automaticallyStart, isEnabled {
            Task { @MainActor [weak self] in
                self?.start()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        enabled ? start() : stop()
    }

    @discardableResult
    func setPort(_ value: Int) -> Bool {
        guard let validPort = Self.validPort(value) else {
            state = .failed("El puerto debe estar entre 1024 y 65535.")
            return false
        }
        guard !isEnabled else {
            state = .failed("Desactiva el acceso MCP antes de cambiar el puerto.")
            return false
        }
        port = validPort
        defaults.set(validPort, forKey: Self.portKey)
        state = .stopped
        return true
    }

    func retry() {
        guard isEnabled else { return }
        stopProcess(updateState: false)
        start()
    }

    func start() {
        guard isEnabled else {
            state = .stopped
            return
        }
        guard process?.isRunning != true else { return }

        guard let serverURL = Self.discoverServerURL() else {
            state = .failed(
                "No se encontró el servidor MCP dentro de MeetTracker.app. "
                + "Vuelve a generar la aplicación."
            )
            return
        }
        guard let nodeURL = Self.discoverNodeURL() else {
            state = .failed(
                "No se encontró una instalación funcional de Node.js 20 o posterior."
            )
            return
        }

        generation += 1
        let currentGeneration = generation
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = nodeURL
        process.arguments = [serverURL.path]
        process.currentDirectoryURL = serverURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["MEETTRACKER_MCP_HOST"] = "127.0.0.1"
        environment["MEETTRACKER_MCP_PORT"] = String(port)
        environment["NODE_ENV"] = "production"
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        self.process = process
        state = .starting
        logMessage = "Iniciando el servidor local…"

        observe(outputPipe, process: process, generation: currentGeneration)
        observe(errorPipe, process: process, generation: currentGeneration)
        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            Task { @MainActor in
                guard let self,
                      let process,
                      self.generation == currentGeneration,
                      self.process === process else { return }
                self.process = nil
                if self.isEnabled {
                    let detail = self.logMessage.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    self.state = .failed(
                        detail.isEmpty
                            ? "El servidor MCP terminó inesperadamente "
                                + "(código \(terminatedProcess.terminationStatus))."
                            : detail
                    )
                } else {
                    self.state = .stopped
                }
            }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        stopProcess(updateState: true)
    }

    private func stopProcess(updateState: Bool) {
        generation += 1
        let runningProcess = process
        process = nil
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
        if updateState {
            state = .stopped
            logMessage = ""
        }
    }

    private func observe(_ pipe: Pipe, process: Process, generation: Int) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self,
                      let process,
                      self.generation == generation,
                      self.process === process else { return }
                self.appendLog(text)
                if text.contains("MeetTracker MCP escuchando en") {
                    self.state = .running
                }
            }
        }
    }

    private func appendLog(_ text: String) {
        logMessage += text
        if logMessage.count > 2_000 {
            logMessage = String(logMessage.suffix(2_000))
        }
    }

    @objc private func applicationWillTerminate() {
        stopProcess(updateState: false)
    }

    private static func validPort(_ value: Int) -> Int? {
        (1024...65_535).contains(value) ? value : nil
    }

    private static func discoverServerURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent("MeetTrackerMCP", isDirectory: true)
                    .appendingPathComponent("src", isDirectory: true)
                    .appendingPathComponent("server.mjs")
            )
        }

        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Tools/MeetTrackerMCP/src/server.mjs")
        )

        if var ancestor = Bundle.main.executableURL?.deletingLastPathComponent() {
            for _ in 0..<8 {
                candidates.append(
                    ancestor.appendingPathComponent("Tools/MeetTrackerMCP/src/server.mjs")
                )
                ancestor.deleteLastPathComponent()
            }
        }

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func discoverNodeURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let configured = ProcessInfo.processInfo.environment["MEETTRACKER_NODE_BIN"] {
            candidates.append(URL(fileURLWithPath: configured))
        }

        let versionsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions
                .sorted {
                    $0.lastPathComponent.compare(
                        $1.lastPathComponent,
                        options: .numeric
                    ) == .orderedDescending
                }
                .map { $0.appendingPathComponent("bin/node") })
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node")
        ])

        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.path) && nodeIsUsable($0)
        }
    }

    private static func nodeIsUsable(_ url: URL) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let version = String(data: data, encoding: .utf8) ?? ""
            let major = version
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { !$0.isNumber })
                .prefix(while: { $0.isNumber })
            return Int(major).map { $0 >= 20 } ?? false
        } catch {
            return false
        }
    }
}

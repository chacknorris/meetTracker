import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            TranscriptionSettingsView()
                .tabItem {
                    Label("Transcripción", systemImage: "waveform.and.mic")
                }

            DiarizationSettingsView()
                .tabItem {
                    Label("Participantes", systemImage: "person.2.wave.2")
                }

            MCPSettingsView()
                .tabItem {
                    Label("ChatGPT", systemImage: "server.rack")
                }
        }
        .padding(12)
        .frame(width: 680, height: 580)
    }
}

private struct MCPSettingsView: View {
    @EnvironmentObject private var mcpServer: MCPServerController
    @State private var portText = ""
    @State private var copiedEndpoint = false

    private var parsedPort: Int? {
        Int(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var portIsValid: Bool {
        parsedPort.map { (1024...65_535).contains($0) } ?? false
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Permitir consultas desde ChatGPT",
                    isOn: Binding(
                        get: { mcpServer.isEnabled },
                        set: { mcpServer.setEnabled($0) }
                    )
                )

                HStack {
                    Label(
                        mcpServer.state.title,
                        systemImage: mcpServer.state.systemImage
                    )
                    .foregroundStyle(stateColor)

                    Spacer()

                    if case .failed = mcpServer.state, mcpServer.isEnabled {
                        Button("Reintentar") {
                            mcpServer.retry()
                        }
                    }
                }

                if case let .failed(message) = mcpServer.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                LabeledContent("Endpoint local") {
                    HStack(spacing: 8) {
                        Text(mcpServer.endpoint)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                mcpServer.endpoint,
                                forType: .string
                            )
                            copiedEndpoint = true
                        } label: {
                            Image(
                                systemName: copiedEndpoint
                                    ? "checkmark"
                                    : "doc.on.doc"
                            )
                        }
                        .help("Copiar endpoint")
                    }
                }

                LabeledContent("Puerto") {
                    HStack {
                        TextField("3210", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .disabled(mcpServer.isEnabled)
                            .onSubmit(savePort)

                        Button("Guardar") {
                            savePort()
                        }
                        .disabled(
                            mcpServer.isEnabled
                                || !portIsValid
                                || parsedPort == mcpServer.port
                        )
                    }
                }

                if mcpServer.isEnabled {
                    Text("Desactiva el servidor para cambiar el puerto.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !portText.isEmpty, !portIsValid {
                    Text("Usa un puerto entre 1024 y 65535.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Servidor MCP local")
            } footer: {
                Text(
                    "Al activarlo, MeetTracker inicia el servidor automáticamente "
                    + "cada vez que abres la app y lo detiene al salir."
                )
            }

            Section {
                Link(
                    "Abrir guía de Secure MCP Tunnel",
                    destination: URL(
                        string: "https://developers.openai.com/api/docs/guides/secure-mcp-tunnels"
                    )!
                )

                Link(
                    "Abrir configuración de apps en ChatGPT",
                    destination: URL(string: "https://chatgpt.com/#settings/Apps")!
                )

                Text(
                    "ChatGPT Pro puede usar estas herramientas de lectura desde "
                    + "la web. El túnel seguro conecta este endpoint local sin "
                    + "publicarlo en Internet."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Conexión con ChatGPT Pro")
            }

            Section("Privacidad") {
                Label(
                    "Sólo lectura: reuniones, participantes y transcripciones",
                    systemImage: "lock.shield"
                )
                Label(
                    "Los archivos de audio nunca se exponen mediante MCP",
                    systemImage: "waveform.badge.exclamationmark"
                )
                Text(
                    "Whisper y pyannote continúan procesando localmente. "
                    + "ChatGPT recibe únicamente los datos que solicitas en la conversación."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(mcpServer.port)
        }
        .onChange(of: mcpServer.port) { newValue in
            portText = String(newValue)
        }
    }

    private var stateColor: Color {
        switch mcpServer.state {
        case .running:
            return .green
        case .failed:
            return .red
        case .starting:
            return .orange
        case .stopped:
            return .secondary
        }
    }

    private func savePort() {
        guard let parsedPort else { return }
        if mcpServer.setPort(parsedPort) {
            portText = String(mcpServer.port)
        }
    }
}

private struct TranscriptionSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Sistema de transcripción") {
                Picker("Motor", selection: $appModel.transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.segmented)

                if appModel.transcriptionEngine == .localWhisper {
                    Label(
                        appModel.hasLocalTranscriber
                            ? "Faster Whisper está instalado y disponible"
                            : "No se encontró ../transkriptor/venv",
                        systemImage: appModel.hasLocalTranscriber
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(appModel.hasLocalTranscriber ? .green : .orange)
                } else {
                    Label(
                        "Apple Speech usa el servicio de reconocimiento incluido en macOS",
                        systemImage: "apple.logo"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            if appModel.transcriptionEngine == .localWhisper {
                Section {
                    Picker("Modelo", selection: $appModel.whisperModel) {
                        ForEach(WhisperModelOption.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }

                    HStack {
                        let installed = appModel.isWhisperModelInstalled(
                            appModel.whisperModel
                        )
                        Label(
                            installed ? "Modelo instalado" : "Se descargará al primer uso",
                            systemImage: installed
                                ? "internaldrive.fill"
                                : "arrow.down.circle"
                        )
                        .foregroundStyle(installed ? .green : .orange)
                        Spacer()
                        Text(appModel.whisperModel.approximateSize)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Idioma del audio", selection: $appModel.transcriptionLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }

                    Picker("Resultado", selection: $appModel.whisperTaskMode) {
                        ForEach(WhisperTaskMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if appModel.whisperTaskMode == .translate {
                        Label(
                            "Whisper traduce el audio directamente al inglés. "
                            + "No permite elegir otro idioma de destino.",
                            systemImage: "character.book.closed"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if appModel.whisperModel == .largeV3 {
                        Label(
                            "Large v3 puede generar mucha presión de memoria y tardar "
                            + "bastante en reuniones largas. Small es la opción "
                            + "recomendada para un Mac de 16 GB.",
                            systemImage: "memorychip"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Whisper local")
                } footer: {
                    Text(
                        "Small ya está instalado y ofrece un buen equilibrio. "
                        + "Medium y Large v3 son más precisos, pero usan más memoria "
                        + "y tardan más en reuniones largas."
                    )
                }
            } else {
                Section("Apple Speech") {
                    Picker("Idioma", selection: $appModel.transcriptionLanguage) {
                        ForEach(
                            TranscriptionLanguage.allCases.filter {
                                $0 != .automatic
                            }
                        ) { language in
                            Text(language.title).tag(language)
                        }
                    }

                    Label(
                        "Apple Speech transcribe, pero no traduce ni separa "
                        + "participantes remotos.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(
                    "Los cambios se aplican a la próxima reunión o cuando presiones "
                    + "Reintentar en una reunión existente."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DiarizationSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var huggingFaceToken = ""
    @State private var showingSavedConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Separar participantes remotos",
                    isOn: $appModel.diarizationEnabled
                )
                .disabled(
                    !appModel.hasLocalTranscriber
                    || appModel.transcriptionEngine != .localWhisper
                )

                if appModel.transcriptionEngine != .localWhisper {
                    Label(
                        "Selecciona Whisper local para habilitar la diarización.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }

                SecureField(
                    appModel.hasDiarizationKey
                        ? "Hugging Face ya está autorizado"
                        : "Token hf_…",
                    text: $huggingFaceToken
                )
                .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Guardar token") {
                        appModel.saveHuggingFaceToken(huggingFaceToken)
                        huggingFaceToken = ""
                        showingSavedConfirmation = true
                    }
                    .disabled(
                        huggingFaceToken
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )

                    if appModel.hasDiarizationKey {
                        Label("Autorizado", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Link(
                    "Aceptar el modelo pyannote 3.1",
                    destination: URL(
                        string: "https://huggingface.co/pyannote/speaker-diarization-3.1"
                    )!
                )
                Link(
                    "Crear token de Hugging Face",
                    destination: URL(string: "https://huggingface.co/settings/tokens")!
                )
            } header: {
                Text("Identificación de participantes")
            } footer: {
                Text(
                    "Pyannote procesa las voces en este Mac. Hugging Face solo "
                    + "distribuye los modelos y el token queda en el Keychain."
                )
            }
        }
        .formStyle(.grouped)
        .alert("Token guardado", isPresented: $showingSavedConfirmation) {
            Button("Aceptar", role: .cancel) {}
        }
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var deletionTarget: MeetingSession?

    var body: some View {
        NavigationSplitView {
            List(selection: $appModel.selection) {
                Section("Reuniones") {
                    ForEach(appModel.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deletionTarget = session
                                } label: {
                                    Label("Eliminar reunión…", systemImage: "trash")
                                }
                                .disabled(!appModel.canDelete(session))
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
            .overlay {
                if appModel.sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Aún no hay reuniones")
                            .font(.headline)
                        Text("Inicia una grabación para crear la primera.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
        } detail: {
            if let session = appModel.selectedSession {
                SessionDetailView(session: session) {
                    deletionTarget = session
                }
                    .id(session)
            } else {
                WelcomeView()
            }
        }
        .toolbar { mainToolbar }
        .sheet(item: $deletionTarget) { session in
            DeleteMeetingView(session: session)
                .environmentObject(appModel)
        }
        .alert(
            "MeetTracker",
            isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )
        ) {
            Button("Aceptar", role: .cancel) {}
            Button("Abrir Configuración") {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        } message: {
            Text(appModel.errorMessage ?? "Ocurrió un error.")
        }
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if appModel.isRecording {
                HStack(spacing: 7) {
                    Image(systemName: "mic.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appModel.microphoneName ?? "Micrófono")
                            .font(.caption)
                            .lineLimit(1)
                        ProgressView(value: appModel.microphoneLevel)
                            .frame(width: 90)
                    }
                }
                .help("Habla y verifica que el nivel del micrófono se mueva")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            RecordButton()
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Tus reuniones, en un solo lugar")
                    .font(.largeTitle.bold())
                Text("Graba el audio de cualquier app junto con tu micrófono\ny genera una transcripción automática.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await appModel.startRecording() }
            } label: {
                Label("Iniciar primera grabación", systemImage: "record.circle")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var appModel: AppModel
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.title)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack {
                Text(session.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                Spacer()
                if session.transcriptionState == .transcribing {
                    if let progress = appModel.progress(for: session) {
                        Text(
                            progress.fraction,
                            format: .percent.precision(.fractionLength(0))
                        )
                        .monospacedDigit()
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    Text(session.duration.durationLabel)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct RecordButton: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Button {
            Task {
                if appModel.isRecording {
                    await appModel.stopRecording()
                } else {
                    await appModel.startRecording()
                }
            }
        } label: {
            Label(
                appModel.isRecording
                    ? "Detener \(appModel.elapsed.durationLabel)"
                    : "Grabar nueva reunión",
                systemImage: appModel.isRecording ? "stop.fill" : "record.circle"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(appModel.isRecording ? .red : .accentColor)
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

extension TimeInterval {
    var durationLabel: String {
        let total = max(0, Int(self))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

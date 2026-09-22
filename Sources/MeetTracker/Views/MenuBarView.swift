import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if appModel.isRecording {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Grabando · \(appModel.elapsed.durationLabel)",
                        systemImage: "record.circle.fill"
                    )
                    .foregroundStyle(.red)
                    Label(appModel.microphoneName ?? "Micrófono", systemImage: "mic.fill")
                        .font(.caption)
                    ProgressView(value: appModel.microphoneLevel)
                        .help("Habla y verifica que el nivel se mueva")
                }
            } else {
                Text("Listo para grabar")
                    .foregroundStyle(.secondary)
            }

            Divider()

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
                        ? "Detener reunión actual"
                        : "Grabar nueva reunión",
                    systemImage: appModel.isRecording ? "stop.fill" : "record.circle"
                )
            }

            Button("Mostrar MeetTracker") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }

            Divider()
            Button("Salir") { NSApp.terminate(nil) }
        }
        .padding(8)
        .frame(width: 230)
    }
}

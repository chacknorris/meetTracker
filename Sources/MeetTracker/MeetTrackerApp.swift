import SwiftUI

@main
struct MeetTrackerApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var mcpServerController = MCPServerController()

    init() {
        DiagnosticRunner.runIfRequested()
    }

    var body: some Scene {
        Window("MeetTracker", id: "main") {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 920, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(
                    appModel.isRecording
                        ? "Detener reunión actual"
                        : "Iniciar nueva reunión"
                ) {
                    Task {
                        if appModel.isRecording {
                            await appModel.stopRecording()
                        } else {
                            await appModel.startRecording()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appModel)
        } label: {
            Label(
                appModel.isRecording ? "MeetTracker grabando" : "MeetTracker",
                systemImage: appModel.isRecording ? "record.circle.fill" : "waveform.circle"
            )
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .environmentObject(mcpServerController)
        }
    }
}

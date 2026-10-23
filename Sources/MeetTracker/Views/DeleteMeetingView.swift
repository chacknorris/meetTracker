import SwiftUI

struct DeleteMeetingView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: MeetingSession
    @State private var hasConfirmed = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("¿Eliminar esta reunión?", systemImage: "trash")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(session.startedAt.formatted(date: .long, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Text("Se moverá a la Papelera la carpeta completa de esta reunión, incluidos los audios, la transcripción y los datos de participantes. Dejará de aparecer en MeetTracker.")
            Text("Puedes recuperar sus archivos desde la Papelera hasta que la vacíes.")
                .foregroundStyle(.secondary)

            Toggle("Confirmo que quiero eliminar esta reunión y sus archivos.", isOn: $hasConfirmed)
                .toggleStyle(.checkbox)

            if !appModel.canDelete(session) {
                Text("La reunión no está disponible para eliminar. Espera a que termine su grabación o procesamiento.")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .accessibilityLabel("No se pudo eliminar la reunión. \(errorMessage)")
            }

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button("Mover a la Papelera", role: .destructive) {
                    guard hasConfirmed else { return }
                    do {
                        try appModel.moveToTrash(session)
                        dismiss()
                    } catch {
                        errorMessage = "No se pudo mover la reunión a la Papelera. \(error.localizedDescription)"
                        hasConfirmed = false
                    }
                }
                .disabled(!hasConfirmed || !appModel.canDelete(session))
            }
        }
        .padding(28)
        .frame(width: 490)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { dismiss() }
    }
}

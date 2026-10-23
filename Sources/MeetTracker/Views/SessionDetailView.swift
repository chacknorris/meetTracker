import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    let session: MeetingSession
    let onRequestDeletion: () -> Void
    @State private var titleDraft = ""
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                Divider()
                transcriptSection
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(36)
        }
        .navigationTitle(session.title)
        .onAppear { titleDraft = session.title }
        .onChange(of: session.title) { newTitle in
            guard !isEditingTitle else { return }
            titleDraft = newTitle
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isEditingTitle {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Nombre de la reunión", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.largeTitle.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(
                                    isTitleFocused
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.45),
                                    lineWidth: isTitleFocused ? 3 : 1
                                )
                        }
                        .focused($isTitleFocused)
                        .onSubmit(saveTitle)

                    HStack {
                        Spacer()
                        Button(action: saveTitle) {
                            Label("Guardar", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            titleDraft
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )

                        Button(action: cancelTitleEditing) {
                            Label("Cancelar", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(session.title)
                        .font(.largeTitle.bold())
                        .textSelection(.enabled)

                    Button {
                        titleDraft = session.title
                        isEditingTitle = true
                        Task { @MainActor in isTitleFocused = true }
                    } label: {
                        Label("Renombrar", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .help("Cambiar el nombre de esta reunión")
                }
            }

            HStack(spacing: 16) {
                Label(
                    session.startedAt.formatted(date: .long, time: .shortened),
                    systemImage: "calendar"
                )
                Label(
                    session.duration.durationLabel,
                    systemImage: "clock"
                )
                Spacer()
                Button {
                    appModel.reveal(session)
                } label: {
                    Label("Ver archivos", systemImage: "folder")
                }
                Button(role: .destructive, action: onRequestDeletion) {
                    Label("Eliminar…", systemImage: "trash")
                }
                .disabled(!appModel.canDelete(session))
                .help(
                    appModel.canDelete(session)
                        ? "Revisar y confirmar antes de mover esta reunión a la Papelera"
                        : "Espera a que termine la grabación o el procesamiento de esta reunión"
                )
            }
            .foregroundStyle(.secondary)
        }
    }

    private func saveTitle() {
        let cleaned = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        appModel.rename(session, to: cleaned)
        titleDraft = cleaned
        isEditingTitle = false
        isTitleFocused = false
    }

    private func cancelTitleEditing() {
        titleDraft = session.title
        isEditingTitle = false
        isTitleFocused = false
    }

    @ViewBuilder
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Transcripción")
                    .font(.title2.bold())
                Spacer()
                if session.endedAt != nil && session.transcriptionState != .transcribing {
                    Button {
                        appModel.beginTranscription(session)
                    } label: {
                        Label(
                            session.transcriptionState == .notStarted
                                ? "Transcribir"
                                : "Reintentar",
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
            }

            if session.endedAt != nil && session.transcriptionState != .transcribing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Label("Origen de las voces", systemImage: "waveform.and.mic")
                        Picker(
                            "Origen de las voces",
                            selection: Binding(
                                get: {
                                    session.microphoneIncludesAllParticipants == true
                                },
                                set: {
                                    appModel.setMicrophoneIncludesAllParticipants(
                                        for: session,
                                        to: $0
                                    )
                                }
                            )
                        ) {
                            Text("Reunión online").tag(false)
                            Text("Presencial · solo micrófono").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Label("Personas en total", systemImage: "person.2")
                        Picker(
                            "Personas en total",
                            selection: Binding(
                                get: { session.expectedParticipantCount ?? 0 },
                                set: { value in
                                    appModel.setExpectedParticipantCount(
                                        for: session,
                                        to: value == 0 ? nil : value
                                    )
                                }
                            )
                        ) {
                            Text("Detectar automáticamente").tag(0)
                            ForEach(2...12, id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Text(
                            session.microphoneIncludesAllParticipants == true
                                ? "todas hablaron frente al computador"
                                : "incluye tu voz"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                    }

                    if session.microphoneIncludesAllParticipants == true {
                        Label(
                            "Al reintentar, pyannote separará las voces del micrófono. "
                            + "Luego podrás asignar el nombre real a cada una.",
                            systemImage: "person.3.sequence"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }

            switch session.transcriptionState {
            case .completed:
                VStack(alignment: .leading, spacing: 14) {
                    if !appModel.hasLocalTranscriber {
                        ConfigurationBanner(
                            message: "No se encontró el entorno local de Transkriptor. Se usó Apple Speech."
                        )
                    } else if !appModel.diarizationEnabled || !appModel.hasDiarizationKey {
                        HStack {
                            Label(
                                "Los participantes remotos aparecen como “Reunión”. Autoriza pyannote para separarlos localmente.",
                                systemImage: "person.2.badge.gearshape"
                            )
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button("Configurar") {
                                NSApp.sendAction(
                                    Selector(("showSettingsWindow:")),
                                    to: nil,
                                    from: nil
                                )
                            }
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let systemError = session.systemTranscriptionMessage {
                        Label(
                            "La pista de la reunión no se pudo transcribir: \(systemError)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                    if let microphoneError = session.microphoneTranscriptionMessage {
                        Label(
                            "La pista del micrófono no se pudo transcribir: \(microphoneError)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                    if let conversation = appModel.conversation(for: session) {
                        let onlyMicrophoneWasRecognized =
                            !conversation.segments.isEmpty
                            && conversation.segments.allSatisfy {
                                $0.source == .microphone
                            }
                            && conversation.speakerIDs == [ConversationSpeaker.meID]
                        if onlyMicrophoneWasRecognized
                            && session.microphoneIncludesAllParticipants != true {
                            HStack(spacing: 12) {
                                Label(
                                    "Solo se reconoció la pista del micrófono y se "
                                    + "etiquetó completa como “Yo”. Si varias personas "
                                    + "hablaron frente al computador, usa el modo presencial.",
                                    systemImage: "person.3.fill"
                                )
                                .foregroundStyle(.orange)
                                Spacer()
                                Button("Usar modo presencial") {
                                    appModel.setMicrophoneIncludesAllParticipants(
                                        for: session,
                                        to: true
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(12)
                            .background(
                                Color.orange.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        let remoteSpeakerCount = conversation.speakerIDs.filter {
                            $0.hasPrefix(ConversationSpeaker.remotePrefix)
                        }.count
                        if remoteSpeakerCount > 1 {
                            HStack(spacing: 12) {
                                Label(
                                    "Se detectaron \(remoteSpeakerCount) voces remotas. "
                                    + "Si solo hablaron dos personas, puedes unificarlas sin reprocesar.",
                                    systemImage: "person.2.slash"
                                )
                                .foregroundStyle(.orange)
                                Spacer()
                                Button("Corregir a 2 personas") {
                                    appModel.unifyRemoteSpeakersForTwoPersonConversation(
                                        session
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(12)
                            .background(
                                Color.orange.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        ConversationTimelineView(
                            session: session,
                            conversation: conversation
                        )
                    } else {
                        Text(
                            appModel.transcript(for: session)
                                ?? "Reintenta la transcripción para generar la línea de tiempo."
                        )
                        .textSelection(.enabled)
                        .font(.body)
                        .lineSpacing(5)
                    }
                }
            case .transcribing:
                TranscriptionProgressView(
                    progress: appModel.progress(for: session)
                        ?? MeetingTranscriptionProgress(
                            sessionID: session.id,
                            fraction: 0.01,
                            stage: "Iniciando",
                            detail: "Preparando los audios"
                        ),
                    onCancel: { appModel.cancelTranscription(session) }
                )
            case .failed:
                TranscriptEmptyState(
                    title: "No se pudo transcribir",
                    systemImage: "exclamationmark.bubble",
                    message: session.transcriptionMessage ?? "Puedes intentarlo nuevamente."
                )
            case .notStarted:
                TranscriptEmptyState(
                    title: session.endedAt == nil ? "Grabación en curso" : "Lista para transcribir",
                    systemImage: session.endedAt == nil ? "waveform" : "text.bubble",
                    message: session.endedAt == nil
                        ? "La transcripción comenzará al detener la grabación."
                        : "Presiona Transcribir para procesar los audios."
                )
            }
        }
    }
}

private struct ConfigurationBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TranscriptionProgressView: View {
    let progress: MeetingTranscriptionProgress
    let onCancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.stage)
                            .font(.headline)
                        Text(progress.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.monospacedDigit().bold())
                }

                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)

                HStack {
                    Text(
                        "Transcurrido: "
                        + context.date.timeIntervalSince(progress.startedAt).durationLabel
                    )
                    if let remaining = progress.estimatedRemaining(at: context.date) {
                        Text("·")
                        Text("Faltan aprox. \(remaining.durationLabel)")
                    }
                    Spacer()
                    Button("Cancelar", role: .destructive, action: onCancel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct ConversationTimelineView: View {
    @EnvironmentObject private var appModel: AppModel
    let session: MeetingSession
    let conversation: ConversationTranscript
    @State private var draftNames: [String: String] = [:]
    @State private var searchText = ""

    private var matchingSegments: [ConversationSegment] {
        conversation.segments(matching: searchText)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(
                    "\(conversation.segments.count) intervenciones",
                    systemImage: "timeline.selection"
                )
                Text("·")
                Text(conversation.provider)
                Spacer()
                Button {
                    appModel.exportConversation(session)
                } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(
                    "Buscar texto o participante en esta reunión",
                    text: $searchText
                )
                .textFieldStyle(.plain)

                if isSearching {
                    Text(
                        "\(matchingSegments.count) "
                        + (matchingSegments.count == 1 ? "resultado" : "resultados")
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Limpiar búsqueda")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
            }

            if !conversation.speakerIDs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Participantes")
                        .font(.headline)
                    ForEach(conversation.speakerIDs, id: \.self) { speakerID in
                        HStack {
                            Circle()
                                .fill(color(for: speakerID))
                                .frame(width: 9, height: 9)
                            TextField(
                                conversation.displayName(for: speakerID),
                                text: Binding(
                                    get: {
                                        draftNames[speakerID]
                                            ?? conversation.displayName(for: speakerID)
                                    },
                                    set: { draftNames[speakerID] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                appModel.renameSpeaker(
                                    in: session,
                                    speakerID: speakerID,
                                    to: draftNames[speakerID] ?? ""
                                )
                            }
                            if speakerID == ConversationSpeaker.meID {
                                Text("pista del micrófono")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }

            if matchingSegments.isEmpty && isSearching {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No se encontraron coincidencias")
                        .font(.headline)
                    Text("Prueba con otra palabra o con el nombre de un participante.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(matchingSegments) { segment in
                        HStack(alignment: .top, spacing: 12) {
                            Text(segment.startTime.timelineTimestamp)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .leading)

                            Circle()
                                .fill(color(for: segment.speakerID))
                                .frame(width: 10, height: 10)
                                .padding(.top, 5)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.displayName(for: segment.speakerID))
                                    .font(.caption.bold())
                                    .foregroundStyle(color(for: segment.speakerID))
                                Text(segment.text)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(
                            color(for: segment.speakerID).opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                }
            }
        }
        .onAppear {
            draftNames = Dictionary(
                uniqueKeysWithValues: conversation.speakerIDs.map {
                    ($0, conversation.displayName(for: $0))
                }
            )
        }
    }

    private func color(for speakerID: String) -> Color {
        if speakerID == ConversationSpeaker.meID { return .blue }
        let palette: [Color] = [.purple, .orange, .green, .pink, .teal, .indigo]
        let sum = speakerID.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

private struct TranscriptEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
    }
}

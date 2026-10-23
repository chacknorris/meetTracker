import AppKit
import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [MeetingSession] = []
    @Published var selection: MeetingSession.ID?
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var microphoneName: String?
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var transcriptionProgress: [
        MeetingSession.ID: MeetingTranscriptionProgress
    ] = [:]
    @Published var transcriptionEngine: TranscriptionEngine {
        didSet {
            UserDefaults.standard.set(
                transcriptionEngine.rawValue,
                forKey: Self.transcriptionEngineKey
            )
        }
    }
    @Published var whisperModel: WhisperModelOption {
        didSet {
            UserDefaults.standard.set(
                whisperModel.rawValue,
                forKey: Self.whisperModelKey
            )
        }
    }
    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet {
            UserDefaults.standard.set(
                transcriptionLanguage.rawValue,
                forKey: Self.transcriptionLanguageKey
            )
        }
    }
    @Published var whisperTaskMode: WhisperTaskMode {
        didSet {
            UserDefaults.standard.set(
                whisperTaskMode.rawValue,
                forKey: Self.whisperTaskModeKey
            )
        }
    }
    @Published var diarizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(diarizationEnabled, forKey: Self.diarizationEnabledKey)
        }
    }
    @Published private(set) var hasDiarizationKey: Bool
    @Published private(set) var hasLocalTranscriber: Bool
    @Published var errorMessage: String?

    private let repository: MeetingRepository
    private let coordinator: RecordingCoordinator
    private let appleTranscriber: AudioTranscribing
    private let localEnvironment: LocalTranscriptionEnvironment?
    private var timer: Timer?
    private var conversationCache: [MeetingSession.ID: ConversationTranscript] = [:]
    private var transcriptionTasks: [MeetingSession.ID: Task<Void, Never>] = [:]
    private static let diarizationEnabledKey = "diarizationEnabled"
    private static let transcriptionEngineKey = "transcriptionEngine"
    private static let whisperModelKey = "whisperModel"
    private static let transcriptionLanguageKey = "transcriptionLanguage"
    private static let whisperTaskModeKey = "whisperTaskMode"

    init(
        repository: MeetingRepository = MeetingRepository(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriber: AudioTranscribing = SpeechTranscriber(),
        localEnvironment: LocalTranscriptionEnvironment? =
            LocalTranscriptionEnvironment.discover()
    ) {
        self.repository = repository
        self.coordinator = coordinator
        self.appleTranscriber = transcriber
        self.localEnvironment = localEnvironment
        self.transcriptionEngine = TranscriptionEngine(
            rawValue: UserDefaults.standard.string(
                forKey: Self.transcriptionEngineKey
            ) ?? ""
        ) ?? .localWhisper
        self.whisperModel = WhisperModelOption(
            rawValue: UserDefaults.standard.string(
                forKey: Self.whisperModelKey
            ) ?? ""
        ) ?? .small
        self.transcriptionLanguage = TranscriptionLanguage(
            rawValue: UserDefaults.standard.string(
                forKey: Self.transcriptionLanguageKey
            ) ?? ""
        ) ?? .spanish
        self.whisperTaskMode = WhisperTaskMode(
            rawValue: UserDefaults.standard.string(
                forKey: Self.whisperTaskModeKey
            ) ?? ""
        ) ?? .transcribe
        self.diarizationEnabled =
            UserDefaults.standard.object(forKey: Self.diarizationEnabledKey) as? Bool
            ?? true
        self.hasDiarizationKey =
            HuggingFaceTokenStore.load() != nil
            || LocalTranscriptionEnvironment.hasCachedHuggingFaceToken
        self.hasLocalTranscriber = localEnvironment != nil
        reload()
    }

    var selectedSession: MeetingSession? {
        sessions.first { $0.id == selection }
    }

    func startRecording() async {
        guard !isRecording else { return }
        let session = MeetingSession.new()

        do {
            try repository.save(session)
            let activeSession = try await coordinator.start(
                session: session,
                repository: repository
            )
            try repository.save(activeSession)
            sessions.insert(activeSession, at: 0)
            selection = activeSession.id
            isRecording = true
            elapsed = 0
            microphoneName = coordinator.microphoneName
            startTimer()
        } catch {
            errorMessage = error.localizedDescription
            try? FileManager.default.removeItem(at: repository.directoryURL(for: session))
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        isRecording = false
        microphoneLevel = 0
        microphoneName = nil

        guard let completed = await coordinator.stop() else { return }
        do {
            try repository.save(completed)
            replace(completed)
            beginTranscription(completed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginTranscription(_ session: MeetingSession) {
        guard transcriptionTasks[session.id] == nil else { return }
        transcriptionTasks[session.id] = Task { [weak self] in
            guard let self else { return }
            await self.transcribe(session)
            self.transcriptionTasks[session.id] = nil
        }
    }

    func cancelTranscription(_ session: MeetingSession) {
        transcriptionTasks[session.id]?.cancel()
        // Keep tracking the task until it actually exits so its files cannot be
        // moved while cancellation is still unwinding.
        guard var updated = sessions.first(where: { $0.id == session.id }) else {
            return
        }
        updated.transcriptionState = .failed
        updated.transcriptionMessage = "El proceso fue cancelado. Puedes iniciarlo nuevamente."
        transcriptionProgress[session.id] = nil
        try? repository.save(updated)
        replace(updated)
    }

    func progress(for session: MeetingSession) -> MeetingTranscriptionProgress? {
        transcriptionProgress[session.id]
    }

    func transcribe(_ session: MeetingSession) async {
        guard session.endedAt != nil else { return }
        var working = session
        working.transcriptionState = .transcribing
        working.transcriptionMessage = nil
        working.systemTranscriptionMessage = nil
        working.microphoneTranscriptionMessage = nil
        replace(working)
        try? repository.save(working)
        transcriptionProgress[working.id] = MeetingTranscriptionProgress(
            sessionID: working.id,
            fraction: 0.01,
            stage: "Preparando transcripción",
            detail: "Comprobando los dos archivos de audio"
        )

        let locale = transcriptionLanguage.appleLocale
        let systemURL = repository.audioURL(filename: working.systemAudioFilename, for: working)
        let microphoneURL = repository.audioURL(filename: working.microphoneAudioFilename, for: working)

        let systemTranscriber: AudioTranscribing
        let microphoneTranscriber: AudioTranscribing
        let microphoneIncludesAllParticipants =
            working.microphoneIncludesAllParticipants == true
        if transcriptionEngine == .localWhisper, let localEnvironment {
            let token = HuggingFaceTokenStore.load()
            systemTranscriber = LocalWhisperTranscriber(
                environment: localEnvironment,
                diarize: !microphoneIncludesAllParticipants
                    && diarizationEnabled
                    && hasDiarizationKey,
                huggingFaceToken: token,
                numberOfSpeakers: working.expectedParticipantCount.map {
                    max(1, $0 - 1)
                },
                model: whisperModel.rawValue,
                language: transcriptionLanguage.whisperCode,
                taskMode: whisperTaskMode
            )
            microphoneTranscriber = LocalWhisperTranscriber(
                environment: localEnvironment,
                diarize: microphoneIncludesAllParticipants
                    && diarizationEnabled
                    && hasDiarizationKey,
                huggingFaceToken: token,
                numberOfSpeakers: microphoneIncludesAllParticipants
                    ? working.expectedParticipantCount
                    : nil,
                model: whisperModel.rawValue,
                language: transcriptionLanguage.whisperCode,
                taskMode: whisperTaskMode
            )
        } else {
            systemTranscriber = appleTranscriber
            microphoneTranscriber = appleTranscriber
        }

        let system: (transcription: AudioTranscription?, error: String?)
        if microphoneIncludesAllParticipants {
            setProgress(
                sessionID: working.id,
                fraction: 0.02,
                stage: "Reunión presencial",
                detail: "Todas las voces se procesarán desde el micrófono"
            )
            system = (nil, nil)
        } else {
            system = await transcriptionAttempt(
                for: systemURL,
                locale: locale,
                using: systemTranscriber,
                sessionID: working.id,
                range: 0.02...0.72,
                trackName: "Audio de la reunión"
            )
        }
        if Task.isCancelled {
            finishCancelledTranscription(&working)
            return
        }
        let microphone = await transcriptionAttempt(
            for: microphoneURL,
            locale: locale,
            using: microphoneTranscriber,
            sessionID: working.id,
            range: microphoneIncludesAllParticipants
                ? 0.02...0.94
                : 0.72...0.94,
            trackName: microphoneIncludesAllParticipants
                ? "Voces del micrófono"
                : "Tu micrófono"
        )
        if Task.isCancelled {
            finishCancelledTranscription(&working)
            return
        }
        working.systemTranscriptionMessage = system.error
        working.microphoneTranscriptionMessage = microphone.error

        if system.transcription != nil || microphone.transcription != nil {
            do {
                setProgress(
                    sessionID: working.id,
                    fraction: 0.96,
                    stage: "Armando conversación",
                    detail: "Ordenando tiempos y participantes"
                )
                let offsets = await audioOffsets(
                    for: working,
                    systemURL: systemURL,
                    microphoneURL: microphoneURL
                )
                let systemSegments = conversationSegments(
                    from: system.transcription,
                    source: .systemAudio,
                    offset: offsets.system
                )
                let microphoneSegments = conversationSegments(
                    from: microphone.transcription,
                    source: .microphone,
                    offset: offsets.microphone,
                    preserveSpeakerLabels: microphoneIncludesAllParticipants
                )
                let existingNames = repository.conversation(for: working)?.speakerNames ?? [:]
                let conversation = ConversationTranscript(
                    provider: systemTranscriber.providerName,
                    segments: systemSegments + microphoneSegments,
                    speakerNames: existingNames
                )
                try repository.saveConversation(conversation, for: working)
                conversationCache[working.id] = conversation
                working.transcriptFilename = "transcript.md"
                working.conversationFilename = "conversation.json"
                working.transcriptionProvider = systemTranscriber.providerName
                working.transcriptionState = .completed
                working.transcriptionMessage = nil
                setProgress(
                    sessionID: working.id,
                    fraction: 1,
                    stage: "Listo",
                    detail: "\(conversation.segments.count) intervenciones guardadas"
                )
            } catch {
                working.transcriptionState = .failed
                working.transcriptionMessage = error.localizedDescription
            }
        } else {
            working.transcriptionState = .failed
            working.transcriptionMessage = [system.error, microphone.error]
                .compactMap { $0 }
                .first ?? "No se detectó voz en los archivos de audio."
        }

        try? repository.save(working)
        replace(working)
        transcriptionProgress[working.id] = nil
    }

    func saveHuggingFaceToken(_ key: String) {
        do {
            try HuggingFaceTokenStore.save(key)
            hasDiarizationKey =
                HuggingFaceTokenStore.load() != nil
                || LocalTranscriptionEnvironment.hasCachedHuggingFaceToken
            if hasDiarizationKey {
                diarizationEnabled = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeHuggingFaceToken() {
        HuggingFaceTokenStore.remove()
        hasDiarizationKey = LocalTranscriptionEnvironment.hasCachedHuggingFaceToken
    }

    func isWhisperModelInstalled(_ model: WhisperModelOption) -> Bool {
        LocalTranscriptionEnvironment.isWhisperModelCached(model)
    }

    func rename(_ session: MeetingSession, to title: String) {
        var updated = session
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.title.isEmpty {
            updated.title = MeetingSession.defaultTitle(for: updated.startedAt)
        }
        try? repository.save(updated)
        if let conversation = conversation(for: updated) {
            try? repository.saveConversation(conversation, for: updated)
        }
        replace(updated)
    }

    func setExpectedParticipantCount(
        for session: MeetingSession,
        to participantCount: Int?
    ) {
        var updated = session
        if let participantCount {
            updated.expectedParticipantCount = min(12, max(2, participantCount))
        } else {
            updated.expectedParticipantCount = nil
        }
        try? repository.save(updated)
        replace(updated)
    }

    func setMicrophoneIncludesAllParticipants(
        for session: MeetingSession,
        to enabled: Bool
    ) {
        var updated = session
        updated.microphoneIncludesAllParticipants = enabled
        try? repository.save(updated)
        replace(updated)
    }

    func unifyRemoteSpeakersForTwoPersonConversation(_ session: MeetingSession) {
        guard let existing = conversation(for: session) else { return }
        let targetSpeakerID = ConversationSpeaker.remotePrefix + "SPEAKER_00"
        let remapped = existing.segments.map { segment -> ConversationSegment in
            guard segment.source == .systemAudio else { return segment }
            var updated = segment
            updated.speakerID = targetSpeakerID
            return updated
        }
        let merged = mergeAdjacentSegments(remapped)

        var names = existing.speakerNames
        let previousRemoteNames = existing.speakerIDs.compactMap { speakerID -> String? in
            guard speakerID.hasPrefix(ConversationSpeaker.remotePrefix) else {
                return nil
            }
            return existing.speakerNames[speakerID]
        }
        names = names.filter {
            !$0.key.hasPrefix(ConversationSpeaker.remotePrefix)
        }
        if let preferredName = previousRemoteNames.first {
            names[targetSpeakerID] = preferredName
        }

        let refined = ConversationTranscript(
            generatedAt: existing.generatedAt,
            provider: existing.provider,
            segments: merged,
            speakerNames: names
        )
        var updatedSession = session
        updatedSession.expectedParticipantCount = 2
        do {
            try repository.saveConversation(refined, for: updatedSession)
            try repository.save(updatedSession)
            conversationCache[session.id] = refined
            replace(updatedSession)
            objectWillChange.send()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func transcript(for session: MeetingSession) -> String? {
        repository.transcript(for: session)
    }

    func conversation(for session: MeetingSession) -> ConversationTranscript? {
        if let cached = conversationCache[session.id] {
            return cached
        }
        guard let conversation = repository.conversation(for: session) else {
            return nil
        }
        conversationCache[session.id] = conversation
        return conversation
    }

    func renameSpeaker(in session: MeetingSession, speakerID: String, to name: String) {
        guard var conversation = conversation(for: session) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            conversation.speakerNames.removeValue(forKey: speakerID)
        } else {
            conversation.speakerNames[speakerID] = cleaned
        }
        do {
            try repository.saveConversation(conversation, for: session)
            conversationCache[session.id] = conversation
            objectWillChange.send()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportConversation(_ session: MeetingSession) {
        guard let conversation = conversation(for: session) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(session.title).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try conversation.markdown(title: session.title, startedAt: session.startedAt)
                .write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reveal(_ session: MeetingSession) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.directoryURL(for: session)])
    }

    func canDelete(_ session: MeetingSession) -> Bool {
        guard let current = sessions.first(where: { $0.id == session.id }) else { return false }
        return coordinator.activeSession?.id != current.id
            && current.transcriptionState != .transcribing
            && transcriptionTasks[current.id] == nil
            && transcriptionProgress[current.id] == nil
    }

    func moveToTrash(_ session: MeetingSession) throws {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            throw MeetingDeletionError.unavailable
        }
        let current = sessions[index]
        guard canDelete(current) else { throw MeetingDeletionError.busy }

        try repository.moveToTrash(current)
        sessions.remove(at: index)
        conversationCache[current.id] = nil
        transcriptionProgress[current.id] = nil
        if selection == current.id {
            selection = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
    }

    func reload() {
        do {
            sessions = try repository.loadAll().map { session in
                guard session.transcriptionState == .transcribing,
                      transcriptionTasks[session.id] == nil else {
                    return session
                }
                var recovered = session
                recovered.transcriptionState = .failed
                recovered.transcriptionMessage =
                    "La app se cerró antes de terminar el proceso anterior. "
                    + "Los audios están intactos; presiona Reintentar."
                try? repository.save(recovered)
                return recovered
            }
            if selection == nil {
                selection = sessions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replace(_ session: MeetingSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsed += 0.25
                let decibels = Double(self.coordinator.microphonePower)
                self.microphoneLevel = decibels <= -60
                    ? 0
                    : min(1, pow(10, decibels / 20))
            }
        }
    }

    private func transcriptionAttempt(
        for url: URL,
        locale: Locale,
        using transcriber: AudioTranscribing,
        sessionID: MeetingSession.ID,
        range: ClosedRange<Double>,
        trackName: String
    ) async -> (transcription: AudioTranscription?, error: String?) {
        do {
            let result = try await transcriber.transcribe(
                fileAt: url,
                locale: locale
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let scaled = range.lowerBound
                        + (range.upperBound - range.lowerBound) * progress.fraction
                    self.setProgress(
                        sessionID: sessionID,
                        fraction: scaled,
                        stage: "\(trackName): \(progress.stage)",
                        detail: progress.detail
                    )
                }
            }
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (nil, nil)
                : (result, nil)
        } catch is CancellationError {
            return (nil, "Proceso cancelado.")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func setProgress(
        sessionID: MeetingSession.ID,
        fraction: Double,
        stage: String,
        detail: String
    ) {
        let startedAt = transcriptionProgress[sessionID]?.startedAt ?? Date()
        transcriptionProgress[sessionID] = MeetingTranscriptionProgress(
            sessionID: sessionID,
            fraction: fraction,
            stage: stage,
            detail: detail,
            startedAt: startedAt
        )
    }

    private func finishCancelledTranscription(_ session: inout MeetingSession) {
        session.transcriptionState = .failed
        session.transcriptionMessage =
            "El proceso fue cancelado. Los audios siguen guardados y puedes reintentarlo."
        transcriptionProgress[session.id] = nil
        try? repository.save(session)
        replace(session)
    }

    private func conversationSegments(
        from transcription: AudioTranscription?,
        source: ConversationSegment.Source,
        offset: TimeInterval,
        preserveSpeakerLabels: Bool = false
    ) -> [ConversationSegment] {
        guard let transcription else { return [] }
        let raw = transcription.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { segment -> ConversationSegment in
                let speakerID: String
                if source == .microphone {
                    if preserveSpeakerLabels, let label = segment.speakerLabel {
                        speakerID = ConversationSpeaker.remotePrefix + label
                    } else if preserveSpeakerLabels {
                        speakerID = ConversationSpeaker.meetingID
                    } else {
                        speakerID = ConversationSpeaker.meID
                    }
                } else if let label = segment.speakerLabel {
                    speakerID = ConversationSpeaker.remotePrefix + label
                } else {
                    speakerID = ConversationSpeaker.meetingID
                }
                return ConversationSegment(
                    speakerID: speakerID,
                    startTime: segment.startTime + offset,
                    endTime: segment.endTime + offset,
                    text: segment.text,
                    source: source
                )
            }

        return mergeAdjacentSegments(raw)
    }

    private func mergeAdjacentSegments(
        _ segments: [ConversationSegment]
    ) -> [ConversationSegment] {
        var merged: [ConversationSegment] = []
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            if var previous = merged.last,
               previous.speakerID == segment.speakerID,
               segment.startTime - previous.endTime <= 1.2,
               segment.endTime - previous.startTime <= 18 {
                previous.endTime = max(previous.endTime, segment.endTime)
                let separator = previous.text.last.map { ".?!,".contains($0) } == true ? " " : " "
                previous.text += separator + segment.text
                merged[merged.count - 1] = previous
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private func audioOffsets(
        for session: MeetingSession,
        systemURL: URL,
        microphoneURL: URL
    ) async -> (system: TimeInterval, microphone: TimeInterval) {
        if let system = session.systemAudioStartOffset,
           let microphone = session.microphoneStartOffset {
            return (system, microphone)
        }

        // Legacy sessions did not persist capture start times. Both recorders stop
        // together, so their duration difference is the best available alignment.
        let systemDuration = (try? await AVURLAsset(url: systemURL).load(.duration).seconds) ?? 0
        let microphoneDuration = (try? await AVURLAsset(url: microphoneURL).load(.duration).seconds) ?? 0
        let estimatedSystemDelay = max(0, microphoneDuration - systemDuration)
        let estimatedMicrophoneDelay = max(0, systemDuration - microphoneDuration)
        return (estimatedSystemDelay, estimatedMicrophoneDelay)
    }
}

struct MeetingTranscriptionProgress: Equatable {
    let sessionID: MeetingSession.ID
    let fraction: Double
    let stage: String
    let detail: String
    let startedAt: Date

    init(
        sessionID: MeetingSession.ID,
        fraction: Double,
        stage: String,
        detail: String,
        startedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.fraction = min(1, max(0, fraction))
        self.stage = stage
        self.detail = detail
        self.startedAt = startedAt
    }

    func estimatedRemaining(at date: Date = Date()) -> TimeInterval? {
        guard fraction >= 0.03, fraction < 1 else { return nil }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        guard elapsed >= 3 else { return nil }
        return min(24 * 60 * 60, elapsed * (1 - fraction) / fraction)
    }
}

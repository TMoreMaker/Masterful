import AVFoundation
import AppKit
import AudioCapture
import Foundation
import InputControl
import MasterfulKit
import MasterfulUI
import Observation
import Persistence
import Refinement
import TextInsertion
import Transcription

/// Wires the state machine to the real world.
///
/// This is the only type that knows about every subsystem, and it deliberately
/// contains no policy: it applies an intent to `DictationSession`, then performs
/// whatever effects come back. All the decisions — when to latch, when to give
/// up, how long the HUD lingers — live in the state machine where they can be
/// tested. This file is plumbing, and it should stay that way.
@MainActor
@Observable
public final class DictationCoordinator {

    public enum Readiness: Equatable {
        case starting
        case ready
        case needsAccessibility
        case needsMicrophone
        case downloadingModel
        case failed(String)
    }

    /// Where Whisper is, for Mercor mode. Apple's recogniser stands in until
    /// it is `.ready`, so turning the mode on never leaves the user unable to
    /// dictate while a model downloads.
    public enum WhisperStatus: Equatable {
        case off
        case downloading(Double)
        /// Loading, and on the very first run compiling for the Neural Engine.
        case loading
        case ready
        case failed(String)
    }

    public private(set) var whisperStatus: WhisperStatus = .off

    public private(set) var readiness: Readiness = .starting
    public private(set) var phase: DictationPhase = .idle
    public private(set) var hotkeyActive = false

    /// Live input level, mirrored out for the onboarding microphone test.
    public var onInputLevel: ((AudioLevel) -> Void)?

    private var session = DictationSession()
    /// Backs the budget in `docs/latency.md`. Every stage below opens and closes
    /// one interval here; nothing else in this file knows what a signpost is.
    private let trace = LatencyTrace()

    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore
    private let hud: HUDController
    private let hotkeys: HotkeyEngine
    private let capture = AudioCaptureEngine()
    private let ducker = OutputDucker()
    private let transcriber: any TranscriptionEngine
    /// Mercor mode's recogniser. Loaded only while the mode is on.
    private let whisper = WhisperEngine()
    /// The recogniser for the dictation in flight, chosen when it starts, so
    /// toggling the mode mid-sentence cannot split one answer across two.
    private var activeEngine: any TranscriptionEngine
    /// Follows the field after each dictation, so the fixes you make are logged.
    private let corrections = CorrectionWatcher()

    private var sessionTask: Task<Void, Never>?
    private var audioPumpTask: Task<Void, Never>?
    private var levelPumpTask: Task<Void, Never>?
    private var micTestTask: Task<Void, Never>?

    /// Kept so the history record can report a speaking pace.
    private var captureStartedAt: Date?
    private var lastSpeechDuration: TimeInterval = 0
    /// The transcript before clean-up, retained so history can show both.
    private var lastRawTranscript = ""
    /// Text and spoken commands, in the order they were said. Parsed before
    /// refinement so the model never sees a command and never reformats one.
    private var pendingSegments: [TranscriptSegment] = []

    public init(
        settingsStore: SettingsStore,
        historyStore: HistoryStore,
        transcriber: any TranscriptionEngine = SpeechAnalyzerEngine()
    ) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.transcriber = transcriber
        self.activeEngine = transcriber
        self.hud = HUDController(anchor: settingsStore.settings.hudAnchor)
        self.hotkeys = HotkeyEngine(settings: settingsStore.settings)
        self.hotkeys.onIntent = { [weak self] intent in
            self?.handle(intent)
        }
    }

    private var settings: Settings { settingsStore.settings }

    /// Exposed solely for `HUDPreviewDriver`, so motion work does not require
    /// speaking into the machine.
    var hudForPreview: HUDController { hud }

    /// Typed terms plus anything stored in the vocabulary database.
    private var effectiveVocabulary: [String] {
        var terms = settings.vocabulary
        terms.append(contentsOf: historyStore.vocabularyStrings())
        return Array(Set(terms)).sorted()
    }

    // MARK: - Bootstrap

    public func start() async {
        readiness = .starting

        guard await MicrophonePermission.request() else {
            readiness = .needsMicrophone
            return
        }

        readiness = .downloadingModel
        let preferredFormat: AVAudioFormatBox
        do {
            // Prepare the recogniser first: it names the audio format to capture
            // in, and it is the step that may need to download a model.
            let format = try await transcriber.prepare(
                locale: Locale(identifier: settings.localeIdentifier)
            )
            preferredFormat = AVAudioFormatBox(format)
        } catch {
            Log.lifecycle.error("Transcriber preparation failed: \(error.localizedDescription, privacy: .public)")
            readiness = .failed("Speech model unavailable")
            return
        }

        do {
            try capture.prepare(targetFormat: preferredFormat.format)
        } catch {
            Log.lifecycle.error("Audio preparation failed: \(error.localizedDescription, privacy: .public)")
            readiness = .failed("Microphone unavailable")
            return
        }

        guard AccessibilityPermission.isGranted else {
            // Ask on first run rather than waiting to be asked. The system
            // prompt is also what registers the app in the Accessibility list —
            // without it the user is told to grant permission for an app that
            // does not appear there yet.
            AccessibilityPermission.request()
            readiness = .needsAccessibility
            return
        }

        if settings.mercorMode { loadWhisper() }

        hotkeyActive = hotkeys.start()
        readiness = hotkeyActive ? .ready : .needsAccessibility
        historyStore.pruneRecords(olderThan: settings.historyRetentionDays)
        Log.lifecycle.info("Masterful ready — \(self.settings.triggers.count) binding(s): \(self.settings.triggersDisplayString, privacy: .public)")
    }

    public func retryAfterPermissionChange() async {
        await start()
    }

    /// Stands the hotkey engine down while a new binding is being recorded.
    public func setHotkeyRecording(_ isRecording: Bool) {
        hotkeys.setRecording(isRecording)
    }

    // MARK: - Mercor mode

    /// Mercor mode is on *and* Whisper is ready to take the next dictation.
    public var isUsingWhisper: Bool { settings.mercorMode && whisperStatus == .ready }

    public func setMercorMode(_ on: Bool) {
        settingsStore.update { $0.mercorMode = on }
        if on {
            loadWhisper()
        } else {
            whisperStatus = .off
            Task { [whisper] in await whisper.unload() }
        }
    }

    private func loadWhisper() {
        switch whisperStatus {
        case .ready, .loading, .downloading: return
        case .off, .failed: break
        }
        whisperStatus = WhisperEngine.isDownloaded ? .loading : .downloading(0)
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.reportWhisperDownload(fraction) }
        }
        Task { @MainActor [weak self, whisper] in
            do {
                try await whisper.load(progress: progress)
                guard let self, self.settings.mercorMode else { await whisper.unload(); return }
                self.whisperStatus = .ready
            } catch {
                Log.transcription.error("Whisper failed to load: \(error.localizedDescription, privacy: .public)")
                self?.whisperStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func reportWhisperDownload(_ fraction: Double) {
        guard case .downloading = whisperStatus else { return }
        whisperStatus = fraction < 1 ? .downloading(fraction) : .loading
    }

    /// What clean-up may do right now. Mercor mode overrides the setting: no
    /// language model rewords an answer while it is on.
    private var effectiveRefinement: RefinementMode {
        settings.mercorMode ? .rules : settings.refinement
    }

    public func applySettingsChange() {
        hotkeys.apply(settings: settings)
        hud.setAnchor(settings.hudAnchor)
    }

    public func shutdown() {
        // Quitting mid-watch keeps the fixes made so far.
        corrections.end()
        hotkeys.stop()
        capture.shutdown()
        // Before anything else can fail: quitting with the machine left at a
        // quarter volume would be the app's most annoying possible parting gift.
        ducker.restoreImmediately()
        sessionTask?.cancel()
        audioPumpTask?.cancel()
        levelPumpTask?.cancel()
        micTestTask?.cancel()
    }

    public var isModelReady: Bool {
        switch readiness {
        case .ready, .needsAccessibility: true
        default: false
        }
    }

    // MARK: - Microphone test

    /// Opens the microphone purely to display a level, with no recogniser
    /// attached. Used by onboarding to prove the input works before asking the
    /// user to trust it with a sentence.
    public func startMicTest() {
        guard micTestTask == nil, !phase.isCapturing else { return }
        micTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let streams = try self.capture.start()
                for await level in streams.levels {
                    guard !Task.isCancelled else { break }
                    self.onInputLevel?(level)
                }
            } catch {
                Log.audio.error("Mic test failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func stopMicTest() {
        guard micTestTask != nil else { return }
        micTestTask?.cancel()
        micTestTask = nil
        capture.stop(tail: .zero)
        onInputLevel?(.silence)
    }

    // MARK: - Intent loop

    func handle(_ intent: DictationIntent) {
        // Refuse before the microphone ever opens. Dictating into a password
        // field would route a credential through a recogniser and the clipboard.
        if case .beginListening = intent, SecureInput.isActive {
            apply(.blocked(.secureInputActive))
            return
        }
        if case .beginListening = intent {
            stopMicTest()
            // The hotkey edge. Both intervals are measured from here rather than
            // from the effects they belong to, because what the user is waiting
            // on is the key going down, not our bookkeeping after it.
            trace.begin(.hudPresent)
            trace.begin(.captureStart)
        }
        apply(intent)
    }

    private func apply(_ intent: DictationIntent) {
        // Close whatever this intent completes before the reducer's effects open
        // the next stage, so the intervals nest the way the budget describes.
        switch intent {
        case .finalTranscript: trace.end(.transcribeFinalize)
        case .refined: trace.end(.refine)
        case .delivered:
            trace.end(.insert)
            trace.end(.sessionTotal)
        case .cancel, .failed, .blocked: trace.endAll()
        default: break
        }

        let previous = session.phase
        let effects = session.apply(intent)
        phase = session.phase
        hud.apply(phase: session.phase, transcript: session.transcript)

        // One line per real transition. Volatile transcript updates arrive many
        // times a second and are excluded deliberately — logging those would
        // bury the lifecycle in noise and make the log useless for the thing it
        // exists for, which is answering "what happened to my dictation".
        if previous != session.phase {
            Log.session.info(
                "\(Self.describe(previous), privacy: .public) → \(Self.describe(self.session.phase), privacy: .public)"
            )
        }

        for effect in effects {
            perform(effect)
        }
    }

    private nonisolated static func describe(_ phase: DictationPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .listening(let mode): mode == .latched ? "listening(latched)" : "listening"
        case .transcribing: "transcribing"
        case .refining: "refining"
        case .inserting: "inserting"
        case .delivered(let delivery):
            "delivered(\(delivery.wordCount) words → \(delivery.destination == .clipboard ? "clipboard" : "field"))"
        case .failed(let error): "failed(\(error.userMessage))"
        case .blocked(let reason): "blocked(\(reason.userMessage))"
        }
    }

    private func perform(_ effect: DictationEffect) {
        switch effect {
        case .presentHUD:
            hud.present()
            trace.end(.hudPresent)

        case .dismissHUD(let delay):
            hud.dismiss(after: delay) { [weak self] in
                self?.apply(.dismiss)
            }

        case .startCapture:
            beginCapture()

        case .stopCapture(let tail):
            if let started = captureStartedAt {
                lastSpeechDuration = Date().timeIntervalSince(started)
            }
            capture.stop(tail: tail)
            ducker.restore(after: tail)
            levelPumpTask?.cancel()

        case .finalizeTranscription:
            // Key release. `session.total` is the only figure the user feels;
            // the rest exist to say which part of it went wrong.
            trace.begin(.transcribeFinalize)
            trace.begin(.sessionTotal)
            Task { [activeEngine] in
                do {
                    try await activeEngine.finish()
                } catch {
                    Log.transcription.error("Finalise failed: \(error.localizedDescription, privacy: .public)")
                }
            }

        case .cancelTranscription:
            sessionTask?.cancel()
            audioPumpTask?.cancel()
            levelPumpTask?.cancel()
            Task { [activeEngine] in await activeEngine.cancel() }

        case .refine(let text):
            lastRawTranscript = text
            trace.begin(.refine)
            refine(text)

        case .insert(let text):
            trace.begin(.insert)
            insert(text)

        case .feedback(let feedback):
            play(feedback)
        }
    }

    // MARK: - Capture pipeline

    private func beginCapture() {
        // The previous dictation's watch ends here, keeping what was fixed so
        // far — the next one is about to change the field.
        corrections.end()
        sessionTask?.cancel()
        audioPumpTask?.cancel()
        levelPumpTask?.cancel()
        hud.model.resetLevels()
        captureStartedAt = Date()

        if settings.duckOtherAudio {
            ducker.duck(to: settings.duckLevel)
        }

        // Warm the model while the user is still talking. This is free latency:
        // weight loading costs the better part of a second cold, and we have the
        // whole utterance to hide it in.
        if effectiveRefinement == .onDevice {
            let profile = settings.profile(
                forBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
            FoundationModelsRefiner.prewarm(profile: profile)
        }

        let vocabulary = effectiveVocabulary
        activeEngine = isUsingWhisper ? whisper : transcriber
        hud.model.isMercorMode = isUsingWhisper

        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Order matters: the recogniser must be accepting input before
                // the first buffer arrives, or the opening syllable is dropped.
                let updates = try await self.activeEngine.beginSession(vocabulary: vocabulary)
                let streams = try self.capture.start()

                self.audioPumpTask = Task.detached { [weak self, transcriber = self.activeEngine] in
                    var isFirstBuffer = true
                    for await chunk in streams.audio {
                        if isFirstBuffer {
                            isFirstBuffer = false
                            // The moment the microphone is genuinely live. One
                            // hop to the main actor, once per dictation.
                            await MainActor.run { self?.trace.end(.captureStart) }
                        }
                        await transcriber.append(chunk)
                    }
                }

                self.levelPumpTask = Task { @MainActor [weak self] in
                    for await level in streams.levels {
                        self?.hud.push(level: level)
                    }
                }

                for try await update in updates {
                    guard !Task.isCancelled else { return }
                    if update.isFinal {
                        self.apply(.finalTranscript(update.text))
                    } else {
                        self.apply(.partialTranscript(update.text))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                Log.transcription.error("Session failed: \(error.localizedDescription, privacy: .public)")
                self.apply(.failed(.transcriptionFailed(error.localizedDescription)))
            }
        }
    }

    // MARK: - Refine and insert

    private func refine(_ text: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier

        // Commands are extracted first, deliberately. If the clean-up model saw
        // "dash enter" it would tidy it into prose, and the action would be
        // silently turned back into text.
        let parser = VoiceCommandParser(
            configuration: .init(prefix: settings.voiceCommandPrefix)
        )
        let segments = settings.voiceCommandsEnabled ? parser.parse(text) : [.text(text)]
        // Resolved once, here, so every stage in the ladder shapes the text for
        // the same destination even if the user switches apps mid-flight.
        let profile = settings.profile(forBundleID: bundleID)
        let context = RefinementContext(
            applicationBundleID: bundleID,
            applicationName: frontmost?.localizedName,
            vocabulary: effectiveVocabulary,
            profile: profile
        )
        let refiner = RefinerFactory.make(
            mode: effectiveRefinement,
            profile: profile,
            provider: settings.remoteProvider
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            var refined: [TranscriptSegment] = []
            for segment in segments {
                switch segment {
                case .text(let raw):
                    let output = await refiner.refine(raw, context: context)
                    if !output.isEmpty { refined.append(.text(output)) }
                case .command(let command):
                    refined.append(.command(command))
                }
            }
            self.pendingSegments = refined

            // A dictation can be nothing but commands. The state machine treats
            // empty text as "didn't catch that", so give it the command names —
            // which is also what the HUD and history should show.
            let text = refined.compactMap { if case .text(let t) = $0 { t } else { nil } }
                .joined(separator: " ")
            let display = text.isEmpty ? Self.summarise(refined) : text
            self.apply(.refined(display))
        }
    }

    /// Learns names and jargon, not the ordinary words in between.
    ///
    /// The spellchecker alone is not enough: it counts everyone in Contacts as
    /// a known word, and those are exactly the names a user dictates. So a
    /// capitalised word must also appear in the plain English word list to be
    /// treated as ordinary — "Lerato" fails that, "Sarah" passes, and neither
    /// "the" nor "page" is capitalised mid-fix to begin with.
    private static let learner = VocabularyLearner { word in
        MainActor.assumeIsolated {
            if let first = word.first, first.isUppercase, !englishWords.contains(word.lowercased()) {
                return false
            }
            let checker = NSSpellChecker.shared
            if checker.hasLearnedWord(word) { return false }
            let miss = checker.checkSpelling(
                of: word, startingAt: 0, language: "en", wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            )
            return miss.location == NSNotFound
        }
    }

    /// Webster's list, which ships with macOS. Loaded once, on the first fix.
    private nonisolated static let englishWords: Set<String> = {
        let list = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
        return Set(list.split(separator: "\n").map { $0.lowercased() })
    }()

    /// "Return", or "Select all, then Copy".
    private nonisolated static func summarise(_ segments: [TranscriptSegment]) -> String {
        let names = segments.compactMap { segment -> String? in
            if case .command(let command) = segment { command.displayName } else { nil }
        }
        return names.joined(separator: ", then ")
    }

    private func insert(_ text: String) {
        let coordinator = InsertionCoordinator(strategy: settings.insertion)
        let executor = KeyCommandExecutor()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier
        let appName = frontmost?.localizedName
        // Fall back to a single text segment when commands are off, so this path
        // stays identical for ordinary dictation.
        let segments = pendingSegments.isEmpty ? [TranscriptSegment.text(text)] : pendingSegments

        Task { @MainActor [weak self] in
            guard let self else { return }

            var insertedText = ""
            var destination = Destination.focusedField
            var commandNames: [String] = []

            // Performed in the order they were spoken, so "name dash tab email"
            // fills two fields rather than typing everything into the first.
            for segment in segments {
                switch segment {
                case .text(let piece):
                    switch await coordinator.insert(piece) {
                    case .inserted(let where_):
                        insertedText += insertedText.isEmpty ? piece : " " + piece
                        destination = where_
                    case .failed(let reason):
                        self.apply(.failed(.insertionFailed(reason)))
                        return
                    }
                case .command(let command):
                    guard await executor.perform(command) else {
                        self.apply(.failed(.insertionFailed("Couldn't send \(command.displayName)")))
                        return
                    }
                    commandNames.append(command.displayName)
                }
            }

            let summary = commandNames.isEmpty
                ? nil
                : commandNames.joined(separator: ", then ")

            let record = self.recordHistory(
                finalText: insertedText.isEmpty ? (summary ?? text) : insertedText,
                bundleID: bundleID,
                appName: appName,
                destination: destination
            )
            // Only a plain dictation into a field can be followed: commands move
            // focus or change the text themselves, and the clipboard is not a
            // field at all.
            if let record, commandNames.isEmpty, destination == .focusedField, !insertedText.isEmpty {
                // Terms this watch has taught, so a fix that changes again — "Th"
                // saved mid-word, then "Thando" — takes back what it taught.
                var taught: [String] = []
                self.corrections.begin(inserted: insertedText) { [weak self] result, _ in
                    guard let self else { return }
                    self.historyStore.recordCorrections(result, for: record)
                    let terms = Self.learner.terms(from: result?.edits ?? [])
                    for stale in taught where !terms.contains(where: { $0.caseInsensitiveCompare(stale) == .orderedSame }) {
                        self.historyStore.removeLearnedVocabulary(stale)
                    }
                    taught.removeAll { stale in !terms.contains { $0.caseInsensitiveCompare(stale) == .orderedSame } }
                    // A name you had to fix is taught to the recogniser, so the
                    // next dictation is primed for it rather than repeating it.
                    for term in terms where self.historyStore.addVocabulary(term, isAutomatic: true) {
                        taught.append(term)
                        self.hud.show(.learned(term))
                        Log.lifecycle.info("Learned \(term, privacy: .private) from a correction")
                    }
                }
            }
            self.apply(.delivered(Delivery(
                characterCount: insertedText.count,
                wordCount: insertedText.split(whereSeparator: \.isWhitespace).count,
                destination: destination,
                commandSummary: summary
            )))
            self.pendingSegments = []
        }
    }

    @discardableResult
    private func recordHistory(
        finalText: String,
        bundleID: String?,
        appName: String?,
        destination: Destination
    ) -> DictationRecord? {
        guard settings.historyEnabled else { return nil }
        return historyStore.record(
            rawTranscript: lastRawTranscript,
            finalText: finalText,
            speechDuration: lastSpeechDuration,
            applicationBundleID: bundleID,
            applicationName: appName,
            engineName: activeEngine.displayName,
            refinementMode: effectiveRefinement,
            destination: destination
        )
    }

    private func play(_ feedback: Feedback) {
        guard settings.soundEffects else { return }
        let name: String? = switch feedback {
        case .started: "Tink"
        case .delivered: "Pop"
        case .rejected: "Funk"
        }
        if let name, let sound = NSSound(named: name) {
            sound.volume = 0.35
            sound.play()
        }
    }
}

/// Carries an `AVAudioFormat` across an actor hop.
///
/// `AVAudioFormat` is immutable once created but not marked `Sendable`, and this
/// is the one place a format crosses isolation domains.
struct AVAudioFormatBox: @unchecked Sendable {
    let format: AVAudioFormat?
    init(_ format: AVAudioFormat?) { self.format = format }
}

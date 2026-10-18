import AppKit
import ApplicationServices
import Foundation
import MasterfulKit

/// Watches the field a dictation landed in, to see what the user fixes.
///
/// The edits you make straight after dictating are the only honest measure of
/// recognition there is: you were going to make them anyway, and each one says
/// exactly which word was wrong. So after insertion this reads the field once,
/// follows it while you stay in it, and diffs what you leave behind.
///
/// Fixes are reported as they are made: once typing has paused for
/// `settleDelay`, the watcher reports where the dictation now stands, so a fix
/// is saved — and a name learned — without the user doing anything to end the
/// watch. The watch itself ends when focus moves to another element, when the
/// next dictation starts, or after `maximumWatch`, whichever comes first, and
/// makes one last report then. It never writes to the field, and declines
/// outright for secure input.
///
/// Verified against Chrome with `make probe-corrections-auto` before this was
/// written: the textarea is readable, edits arrive by value-changed
/// notification, and focus moving away is visible. Polling backs the
/// notification up, because an app that registers it is not thereby promising
/// to send it.
@MainActor
public final class CorrectionWatcher {

    /// How long a field is followed. Long enough to re-read a paragraph and fix
    /// it; short enough that unrelated editing later is not mistaken for
    /// correction.
    public static let maximumWatch: Duration = .seconds(120)

    /// How long typing must pause before a fix counts. Long enough to outlast
    /// the pause in the middle of typing a name — a fix saved as "Th" would
    /// teach the vocabulary a word nobody meant — and short enough that the fix
    /// is in before the next sentence is.
    public static let settleDelay: Duration = .milliseconds(2_500)

    private var current: Watch?

    public init() {}

    /// Starts watching the focused field for edits to `inserted`.
    ///
    /// `onUpdate` runs on the main actor each time the dictation settles into a
    /// new state, and once more, with `isFinal`, when the watch ends. Every call
    /// describes the dictation as it now stands, not what changed since the last
    /// — so a later call supersedes an earlier one. The final call carries `nil`
    /// when the field could not be read or the dictation was deleted.
    public func begin(
        inserted: String,
        onUpdate: @escaping @MainActor (_ result: CorrectionResult?, _ isFinal: Bool) -> Void
    ) {
        end()
        guard !inserted.isEmpty, !SecureInput.isActive,
              let app = NSWorkspace.shared.frontmostApplication else { return }
        let watch = Watch(inserted: inserted, pid: app.processIdentifier, onUpdate: onUpdate) { [weak self] finished in
            if self?.current === finished { self?.current = nil }
        }
        current = watch
        watch.start()
    }

    /// Ends the current watch now, keeping whatever the user has done so far.
    public func end() {
        current?.finish()
        current = nil
    }
}

/// One watch over one field.
@MainActor
private final class Watch {
    let inserted: String
    let pid: pid_t
    let onUpdate: @MainActor (CorrectionResult?, Bool) -> Void
    let onEnded: @MainActor (Watch) -> Void

    private var field: AXUIElement?
    private var baseline = ""
    private var span = NSRange()
    private var lastSeen = ""
    private var observer: AXObserver?
    private var poll: Timer?
    private var deadline: Task<Void, Never>?
    private var settle: Task<Void, Never>?
    /// The last state reported, so an unchanged field is not reported twice.
    private var reported: CorrectionResult?
    private var finished = false

    init(
        inserted: String,
        pid: pid_t,
        onUpdate: @escaping @MainActor (CorrectionResult?, Bool) -> Void,
        onEnded: @escaping @MainActor (Watch) -> Void
    ) {
        self.inserted = inserted
        self.pid = pid
        self.onUpdate = onUpdate
        self.onEnded = onEnded
    }

    func start() {
        Task { @MainActor [weak self] in
            // A paste lands asynchronously, and Chrome builds its tree on first
            // ask, so the field is read after a beat and retried briefly.
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !self.finished else { return }
                if self.attach() { return }
            }
            self?.finish(reading: false)
        }
    }

    /// Finds the field and the dictation in it. False to try again.
    private func attach() -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let element = AXBridge.focusedElement(in: app) ?? AXBridge.focusedElement(),
              AXBridge.role(of: element) != "AXSecureTextField",
              let value = AXBridge.value(of: element),
              value.utf16.count <= CorrectionDiff.largestField,
              let span = Self.locate(inserted, in: value, caret: AXBridge.selectedTextRange(of: element))
        else { return false }

        field = element
        baseline = value
        lastSeen = value
        self.span = span
        observe(element, app: app)

        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: CorrectionWatcher.maximumWatch)
            self?.finish()
        }
        return true
    }

    /// Where the dictation sits in the field: ending at the caret when the
    /// caret says so, otherwise its last occurrence.
    static func locate(_ inserted: String, in value: String, caret: CFRange?) -> NSRange? {
        let text = value as NSString
        let length = (inserted as NSString).length
        if let caret, caret.location >= length {
            let candidate = NSRange(location: caret.location - length, length: length)
            if NSMaxRange(candidate) <= text.length, text.substring(with: candidate) == inserted {
                return candidate
            }
        }
        let found = text.range(of: inserted, options: .backwards)
        return found.location == NSNotFound ? nil : found
    }

    private func observe(_ element: AXUIElement, app: AXUIElement) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var created: AXObserver?
        if AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<Watch>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated {
                if name == kAXFocusedUIElementChangedNotification || name == kAXUIElementDestroyedNotification {
                    watch.finish()
                } else {
                    watch.read()
                }
            }
        }, &created) == .success, let created {
            AXObserverAddNotification(created, element, kAXValueChangedNotification as CFString, refcon)
            AXObserverAddNotification(created, element, kAXUIElementDestroyedNotification as CFString, refcon)
            AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            observer = created
        }

        // The fallback, and the check on focus for apps that never announce it.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let field = self.field else { return }
                self.read()
                let app = AXUIElementCreateApplication(self.pid)
                let focused = AXBridge.focusedElement(in: app) ?? AXBridge.focusedElement()
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid,
                   let focused, !CFEqual(focused, field) {
                    self.finish()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func read() {
        guard !finished, let field, let value = AXBridge.value(of: field), value != lastSeen else { return }
        lastSeen = value
        // Each change restarts the clock: the fix is reported once typing stops.
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: CorrectionWatcher.settleDelay)
            guard !Task.isCancelled, let self, !self.finished else { return }
            self.report(isFinal: false)
        }
    }

    private func report(isFinal: Bool) {
        let result = field == nil
            ? nil
            : CorrectionDiff.corrections(baseline: baseline, span: span, final: lastSeen)
        guard isFinal || (result != nil && result != reported) else { return }
        reported = result
        onUpdate(result, isFinal)
    }

    func finish(reading: Bool = true) {
        guard !finished else { return }
        if reading { read() }
        finished = true

        poll?.invalidate()
        poll = nil
        deadline?.cancel()
        settle?.cancel()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil

        report(isFinal: true)
        field = nil
        onEnded(self)
    }
}

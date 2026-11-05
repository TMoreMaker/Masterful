import AppKit
import MasterfulKit
import MasterfulUI
import Persistence
import SwiftUI

/// Opens one of the app's windows over sample data, without the app around it.
///
/// For iterating on the window's pages the way `make preview` iterates on the
/// island: no microphone, no hotkey, and nothing written to the real history —
/// the store is in memory and seeded with eight weeks of dictations and fixes.
///
///   make window-preview                          # Overview
///   make window-preview PAGE=corrections
///   make window-preview PAGE=settings/cleanup
///   make window-preview PAGE=panel/work          # idle, work, empty or blocked
///   MASTERFUL_APPEARANCE=dark make window-preview PAGE=onboarding/hotkey
@main
@MainActor
enum WindowPreview {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        switch ProcessInfo.processInfo.environment["MASTERFUL_APPEARANCE"] {
        case "dark": app.appearance = NSAppearance(named: .darkAqua)
        case "light": app.appearance = NSAppearance(named: .aqua)
        default: break
        }

        let store = try! HistoryStore(inMemory: true)
        seed(store)
        let services = UIServices(
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "masterful-window-preview")!),
            historyStore: store
        )
        services.onShowMain = { services.mainSection = $0 }

        let page = CommandLine.arguments.dropFirst().first ?? "overview"
        let parts = page.split(separator: "/").map(String.init)
        let title: String
        switch parts.first {
        case "settings":
            title = "Masterful Settings"
            let tab = parts.dropFirst().first.flatMap(SettingsTab.init(rawValue:)) ?? .general
            WindowManager.shared.show(.settings, title: title, size: CGSize(width: 560, height: 520), resizable: false) {
                SettingsView(services: services, initialTab: tab)
            }
        case "panel":
            title = "Menu Bar Panel"
            WindowManager.shared.show(.main, title: title, size: CGSize(width: 300, height: 560), resizable: false) {
                PanelPreview(state: parts.dropFirst().first ?? "idle")
            }
        case "onboarding":
            title = "Set up Masterful"
            let name = parts.dropFirst().first ?? "welcome"
            let step = OnboardingStep.allCases.first { String(describing: $0) == name } ?? .welcome
            WindowManager.shared.show(.onboarding, title: title, size: CGSize(width: 660, height: 580), resizable: false) {
                OnboardingView(services: services, initialStep: step)
            }
        default:
            title = "Masterful"
            services.mainSection = parts.first.flatMap(MainSection.init(rawValue:)) ?? .overview
            WindowManager.shared.show(
                .main, title: title, size: CGSize(width: 940, height: 620),
                minimumSize: CGSize(width: 760, height: 520), bridgesToolbar: true
            ) { MainWindowView(services: services) }
        }

        if let window = NSApp.windows.first(where: { $0.title == title }) {
            print("window \(window.windowNumber)")
            fflush(stdout)
            // Activation is cooperative now, and a request made while the
            // launching process still owns focus can be refused, which renders
            // the window inactive (grey controls) in any screenshot. Ask again
            // once launch has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        app.run()
    }

    /// Fixes drawn from the kind real dictation produces, falling week on week.
    static func seed(_ store: HistoryStore) {
        let calendar = Calendar.current
        let fixes: [(String, String, CorrectionKind)] = [
            ("paint", "page", .word), ("pleased", "placed", .word), ("compete", "complete", .word),
            ("lips of", "lack of", .word), ("transfusing", "translucent", .word),
            ("functional. With", "functional, with", .punctuation), ("however, The", "however, the", .punctuation),
        ]
        let sentence = "The simulation is placed front and centre of the page making it the focal point"
        for weeksAgo in (0..<8).reversed() {
            let dictations = 14 + (weeksAgo * 3) % 7
            let errors = max(1, 9 - weeksAgo / 2 - (7 - weeksAgo))
            for index in 0..<dictations {
                let record = store.record(
                    rawTranscript: sentence, finalText: sentence, speechDuration: 9,
                    applicationBundleID: "com.google.Chrome", applicationName: "Google Chrome",
                    engineName: "Apple Speech (on-device)", refinementMode: .rules, destination: .focusedField
                )
                let date = calendar.date(byAdding: .day, value: -(weeksAgo * 7 + index % 5), to: Date())!
                record.createdAt = date
                let edits = index < errors
                    ? [fixes[(index + weeksAgo) % fixes.count]].map { CorrectionEdit(heard: $0.0, written: $0.1, kind: $0.2) }
                    : []
                store.recordCorrections(index == dictations - 1 ? nil : CorrectionResult(correctedText: sentence, edits: edits), for: record)
                for entry in store.corrections(for: record) { entry.createdAt = date }
            }
        }
    }
}

/// The menu bar panel in one state, working, over no real settings.
private struct PanelPreview: View {
    @State private var workMode: Bool
    @State private var refinement = RefinementMode.onDevice
    private let state: String

    init(state: String) {
        self.state = state
        _workMode = State(initialValue: state == "work")
    }

    var body: some View {
        MenuBarPanel(model: MenuBarPanelModel(
            status: state == "blocked" ? "Needs Accessibility access" : "Ready",
            hint: state == "blocked" ? nil : "Hold 🌐 Globe (fn) to dictate\nDouble-tap to keep listening",
            remedies: state == "blocked" ? [.init(title: "Grant Accessibility access…") {}] : [],
            workMode: workMode,
            workModeNote: workMode ? "Whisper on this Mac · clean-up locked to Tidy" : nil,
            setWorkMode: { workMode = $0 },
            refinement: refinement,
            setRefinement: { refinement = $0 },
            lastDictation: state == "empty" ? nil : "Thanks for sending that over. I'll have a proper look this afternoon and come back to you before the end of the day.",
            commands: [
                .init(title: "Open Masterful", key: "o") {},
                .init(title: "History") {},
                .init(title: "Settings…", key: ",") {},
                .init(title: "Run Setup Again…") {},
                .init(title: "Quit Masterful", key: "q") {},
            ]
        ))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

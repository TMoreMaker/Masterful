import MasterfulKit
import Persistence
import SwiftUI

/// The pages of the main window.
public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case overview, history, corrections

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .history: "History"
        case .corrections: "Corrections"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .history: "clock.arrow.circlepath"
        case .corrections: "character.cursor.ibeam"
        }
    }
}

/// Masterful's one ordinary window: a sidebar of pages, the way a Mac app is
/// navigated.
///
/// Settings stays in its own window on purpose. On the Mac preferences are a
/// separate place you visit, not a page among the content, and folding them in
/// here would make this window both a dashboard and a control panel.
public struct MainWindowView: View {
    @Bindable var services: UIServices

    public init(services: UIServices) {
        self.services = services
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { services.mainSection },
                set: { if let section = $0 { services.mainSection = section } }
            )) {
                ForEach(MainSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            // The page's name goes in the title bar, where a Mac window says
            // where you are, rather than repeated as a heading inside it.
            Group {
                switch services.mainSection {
                case .overview: OverviewPage(services: services)
                case .history: HistoryView(services: services)
                case .corrections: CorrectionsPage(services: services)
                }
            }
            .navigationTitle(services.mainSection.title)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

import SwiftUI
import AppKit
import GRDB
import PetCore

enum StatsTab: Hashable {
    case overview, models, growth, work
}

final class StatsSelection: ObservableObject {
    @Published var tab: StatsTab
    init(_ tab: StatsTab) { self.tab = tab }
}

struct StatsWindowView: View {
    @ObservedObject var selection: StatsSelection
    @ObservedObject var watcher: PRWatcher
    @ObservedObject var coordinator: FixCoordinator
    let db: DatabaseQueue
    let config: ConfigYAML

    @State private var showHooks = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection.tab) {
                Text("Overview").tag(StatsTab.overview)
                Text("Models").tag(StatsTab.models)
                Text("成长史").tag(StatsTab.growth)
                Text("工作台").tag(StatsTab.work)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)

            Divider().opacity(0.4)

            // A plain switch (not TabView) so the window's vibrancy shows through;
            // SwiftUI's TabView paints an opaque background.
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.4)

            HStack {
                Spacer()
                Button("钩子设置") { showHooks = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 680, minHeight: 560)
        .sheet(isPresented: $showHooks) { HooksInstallView() }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selection.tab {
        case .overview: OverviewTab(db: db)
        case .models:   ModelsTab(db: db)
        case .growth:   GrowthHistoryTab(db: db)
        case .work:     PRWorktableTab(watcher: watcher, coordinator: coordinator, db: db, config: config)
        }
    }
}

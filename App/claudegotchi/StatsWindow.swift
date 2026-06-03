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
            TabView(selection: $selection.tab) {
                OverviewTab(db: db)
                    .tabItem { Text("Overview") }
                    .tag(StatsTab.overview)

                ModelsTab(db: db)
                    .tabItem { Text("Models") }
                    .tag(StatsTab.models)

                GrowthHistoryTab(db: db)
                    .tabItem { Text("成长史") }
                    .tag(StatsTab.growth)

                PRWorktableTab(watcher: watcher, coordinator: coordinator, db: db, config: config)
                    .tabItem { Text("工作台") }
                    .tag(StatsTab.work)
            }

            Divider()

            HStack {
                Spacer()
                Button("钩子设置") { showHooks = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 680, minHeight: 560)
        .padding(.top, 4)
        .sheet(isPresented: $showHooks) { HooksInstallView() }
    }
}

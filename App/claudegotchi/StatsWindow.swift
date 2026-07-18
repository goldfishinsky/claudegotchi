import SwiftUI
import AppKit
import GRDB
import PetCore

enum StatsTab: Hashable {
    case overview, models, growth, work, leaderboard
}

final class StatsSelection: ObservableObject {
    @Published var tab: StatsTab
    init(_ tab: StatsTab) { self.tab = tab }
}

struct StatsWindowView: View {
    @ObservedObject var selection: StatsSelection
    @ObservedObject var watcher: PRWatcher
    @ObservedObject var coordinator: FixCoordinator
    @ObservedObject var syncDriver: LeaderboardSyncDriver
    let db: DatabaseQueue
    let config: ConfigYAML
    let leaderboard: LeaderboardService
    let githubClientID: String

    @State private var showHooks = false
    @State private var showLeaderboardSettings = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        return VStack(spacing: 0) {
            WarmSegmented(selection: $selection.tab, items: [
                (.overview, "Overview"),
                (.models, "Models"),
                (.growth, "成长史"),
                (.work, "工作台"),
                (.leaderboard, "排行榜"),
            ])
            // Top inset clears the native traffic lights under the transparent titlebar.
            .padding(.top, 30)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // A plain switch (not TabView) so the warm surface shows through;
            // SwiftUI's TabView paints its own opaque background.
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Spacer()
                Button("排行榜设置") { showLeaderboardSettings = true }
                    .buttonStyle(WarmButtonStyle())
                Button("钩子设置") { showHooks = true }
                    .buttonStyle(WarmButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 680, minHeight: 560)
        .background { t.windowFill.ignoresSafeArea() }
        .sheet(isPresented: $showHooks) { HooksInstallView() }
        .sheet(isPresented: $showLeaderboardSettings) {
            LeaderboardSettingsView(driver: syncDriver, service: leaderboard, githubClientID: githubClientID)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selection.tab {
        case .overview: OverviewTab(db: db)
        case .models:   ModelsTab(db: db)
        case .growth:   GrowthHistoryTab(db: db)
        case .work:     PRWorktableTab(watcher: watcher, coordinator: coordinator, db: db, config: config)
        case .leaderboard:
            LeaderboardTab(driver: syncDriver, service: leaderboard,
                           openSettings: { showLeaderboardSettings = true })
        }
    }
}

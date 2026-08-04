import SwiftUI

struct ContentView: View {
    @StateObject private var syncViewModel: SyncViewModel

    init() {
        #if DEBUG
        let isDesignPreview = ProcessInfo.processInfo.arguments.contains(
            "-design-preview-sync-summary"
        )
        _syncViewModel = StateObject(
            wrappedValue: isDesignPreview ? .designPreview() : SyncViewModel()
        )
        #else
        _syncViewModel = StateObject(wrappedValue: SyncViewModel())
        #endif
    }

    var body: some View {
        TabView {
            SyncDashboardView(vm: syncViewModel)
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

            SettingsView(syncViewModel: syncViewModel)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .environmentObject(syncViewModel)
    }
}

import SwiftUI

@main
struct WangkaManagerApp: App {
    @StateObject private var state = AppState()
    @StateObject private var dji = DJIModemService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(dji)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("断开设备") { state.disconnect() }
                    .disabled(state.endpoint == nil)
            }
        }
    }
}

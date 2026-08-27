import SwiftUI

@main
struct WiSiMApp: App {
    @StateObject private var state = MobileAppState()
    @StateObject private var callKit = CallKitCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(callKit)
                .task { await state.start() }
        }
    }
}

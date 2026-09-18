import SwiftUI

@main
struct BFA7BridgeApp: App {
    @StateObject private var bluetooth = BluetoothManager()
    @StateObject private var sessions = BFA7SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(sessions)
        }
    }
}

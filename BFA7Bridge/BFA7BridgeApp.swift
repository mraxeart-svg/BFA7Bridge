import SwiftUI

@main
struct BFA7BridgeApp: App {
    @StateObject private var glasses = GlassesTransport()
    @StateObject private var media = MediaTransfer()
    @StateObject private var wifiImportLab = WiFiImportLab()
    @StateObject private var voice = VoiceIO()
    @StateObject private var commands = CommandSession()
    @StateObject private var sessions = BFA7SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(glasses)
                .environmentObject(media)
                .environmentObject(glasses.protocolLab)
                .environmentObject(wifiImportLab)
                .environmentObject(voice)
                .environmentObject(commands)
                .environmentObject(sessions)
        }
    }
}

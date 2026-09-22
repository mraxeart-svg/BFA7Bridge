import SwiftUI

@main
struct BFA7BridgeApp: App {
    @StateObject private var glasses = GlassesTransport()
    @StateObject private var media = MediaTransfer()
    @StateObject private var wifiImportLab = WiFiImportLab()
    @StateObject private var voice = VoiceIO()
    @StateObject private var speech = SpeechTranscriber()
    @StateObject private var systemCapture = SystemCaptureProbe()
    @StateObject private var commands = CommandSession()
    @StateObject private var sessions = BFA7SessionStore()
    @StateObject private var wifiJoiner = BFA7WiFiJoiner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(glasses)
                .environmentObject(media)
                .environmentObject(glasses.protocolLab)
                .environmentObject(wifiImportLab)
                .environmentObject(voice)
                .environmentObject(speech)
                .environmentObject(systemCapture)
                .environmentObject(commands)
                .environmentObject(sessions)
                .environmentObject(wifiJoiner)
        }
    }
}

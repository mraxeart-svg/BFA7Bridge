import Foundation
import AppIntents

@available(iOS 17.0, *)
struct StartBFA7AskIntent: AppIntent {
    static var title: LocalizedStringResource = "Start BFA7 Ask"
    static var description = IntentDescription("Opens BFA7 Bridge Ask mode for a push-to-talk request.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "BFA7 Ask opened")
    }
}

@available(iOS 17.0, *)
struct DescribeLatestCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Describe Latest BFA7 Capture"
    static var description = IntentDescription("Opens BFA7 Bridge to describe the latest glasses capture.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "BFA7 describe request opened")
    }
}

@available(iOS 17.0, *)
struct StopBFA7SessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop BFA7 Session"
    static var description = IntentDescription("Opens BFA7 Bridge to stop the active bridge session.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "BFA7 session opened")
    }
}

@available(iOS 17.0, *)
struct BFA7BridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartBFA7AskIntent(), phrases: ["Start BFA7 Ask in \(.applicationName)"], shortTitle: "BFA7 Ask", systemImageName: "mic.circle")
        AppShortcut(intent: DescribeLatestCaptureIntent(), phrases: ["Describe latest capture in \(.applicationName)"], shortTitle: "Describe Capture", systemImageName: "camera.viewfinder")
        AppShortcut(intent: StopBFA7SessionIntent(), phrases: ["Stop BFA7 session in \(.applicationName)"], shortTitle: "Stop BFA7", systemImageName: "stop.circle")
    }
}

import SwiftUI

@main
struct BFA7ImportTool15App: App {
    @StateObject private var transport = ImportBLETransport()
    @StateObject private var media = ImportMediaProbe()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(transport)
                .environmentObject(media)
        }
    }
}

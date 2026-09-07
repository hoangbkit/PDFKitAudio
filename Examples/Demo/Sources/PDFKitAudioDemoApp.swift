import SwiftUI

@main
struct PDFKitAudioDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1_000, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}

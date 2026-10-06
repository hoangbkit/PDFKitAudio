import SwiftUI

@main
struct PDFKitAudioDemoApp: App {
    var body: some Scene {
        WindowGroup {
#if os(macOS)
            ContentView()
                .frame(minWidth: 1_000, minHeight: 650)
#else
            ContentView()
#endif
        }
#if os(macOS)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
#endif
    }
}

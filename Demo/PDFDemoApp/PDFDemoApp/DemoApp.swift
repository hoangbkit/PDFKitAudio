import SwiftUI

@main
struct PDFDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}

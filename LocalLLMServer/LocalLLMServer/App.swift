import SwiftUI

@main
struct LocalLLMServerApp: App {
    @StateObject private var app = AppState()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(app)
        }
    }
}

import SwiftUI

@main
struct DanceApp: App {
    @State private var savedStore = SavedStore()
    @State private var authStore = AuthStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(savedStore)
                .environment(authStore)
        }
    }
}

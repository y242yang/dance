import SwiftUI

@main
struct DanceApp: App {
    @State private var savedStore = SavedStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(savedStore)
        }
    }
}

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @Environment(AuthStore.self) private var authStore
    @Environment(SavedStore.self) private var savedStore

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(selectedTab: $selectedTab)
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(0)

            NavigationStack {
                ClassListView()
            }
            .tabItem { Label("Classes", systemImage: "calendar") }
            .tag(1)

            NavigationStack {
                profileTabContent
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(2)
        }
        .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
        .onChange(of: authStore.username) { _, newValue in
            savedStore.userId = newValue != nil ? authStore.currentUserId : nil
        }
        .onChange(of: authStore.currentUserId) { _, newValue in
            if newValue == nil { savedStore.userId = nil }
        }
    }

    @ViewBuilder
    private var profileTabContent: some View {
        if !authStore.isSignedIn {
            AuthView()
        } else if authStore.needsUsername {
            ChooseUsernameView()
        } else {
            ProfileView()
        }
    }
}

struct PlaceholderTab: View {
    let title: String
    let icon: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 52))
                    .foregroundStyle(Color(red: 0.62, green: 0.35, blue: 1.0))
                Text(title)
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(.white)
                Text("Coming soon")
                    .foregroundStyle(Color(white: 0.5))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

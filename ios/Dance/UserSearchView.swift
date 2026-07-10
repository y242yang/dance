import SwiftUI

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kAccent = Color(red: 0.62, green: 0.35, blue: 1.0)

struct UserSearchView: View {
    @Environment(AuthStore.self) private var authStore
    @State private var query = ""
    @State private var results: [ProfileRow] = []
    @State private var isSearching = false

    private struct ProfileRow: Decodable, Identifiable {
        let id: UUID
        let username: String
    }

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Search for a username to follow")
                    .foregroundStyle(kSecondary)
            } else if results.isEmpty && !isSearching {
                Text("No users found")
                    .foregroundStyle(kSecondary)
            } else {
                List(results) { profile in
                    NavigationLink {
                        UserProfileView(userId: profile.id)
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 30)).foregroundStyle(kAccent)
                            Text("@\(profile.username)").foregroundStyle(.white)
                        }
                    }
                    .listRowBackground(kBg)
                }
                .listStyle(.plain)
                .background(kBg)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Find Friends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(text: $query, prompt: "Username")
        .task(id: query) { await search() }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let myId = authStore.currentUserId else { results = []; return }
        isSearching = true
        defer { isSearching = false }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard trimmed == query.trimmingCharacters(in: .whitespaces) else { return }

        let matches: [ProfileRow] = (try? await supabase
            .from("profiles")
            .select("id, username")
            .ilike("username", pattern: "%\(trimmed)%")
            .neq("id", value: myId)
            .limit(20)
            .execute()
            .value) ?? []
        results = matches
    }
}

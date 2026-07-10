import SwiftUI

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kAccent = Color(red: 0.62, green: 0.35, blue: 1.0)

struct FollowListView: View {
    enum Kind: Hashable { case followers, following }

    let userId: UUID?
    let kind: Kind

    @State private var profiles: [ProfileRow] = []
    @State private var isLoading = false

    private struct ProfileRow: Decodable, Identifiable {
        let id: UUID
        let username: String
    }

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()
            if isLoading && profiles.isEmpty {
                ProgressView().tint(kAccent)
            } else if profiles.isEmpty {
                Text(kind == .followers ? "No followers yet" : "Not following anyone yet")
                    .foregroundStyle(kSecondary)
            } else {
                List(profiles) { profile in
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
        .navigationTitle(kind == .followers ? "Followers" : "Following")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        guard let userId else { return }
        isLoading = true
        defer { isLoading = false }

        let column = kind == .followers ? "following_id" : "follower_id"
        let selectColumn = kind == .followers ? "follower_id" : "following_id"

        struct IdRow: Decodable {
            let followerId: UUID?
            let followingId: UUID?
            enum CodingKeys: String, CodingKey {
                case followerId = "follower_id"
                case followingId = "following_id"
            }
        }

        let rows: [IdRow] = (try? await supabase
            .from("follows")
            .select(selectColumn)
            .eq(column, value: userId)
            .eq("status", value: "accepted")
            .execute()
            .value) ?? []
        let ids = rows.compactMap { kind == .followers ? $0.followerId : $0.followingId }
        guard !ids.isEmpty else { profiles = []; return }

        profiles = (try? await supabase
            .from("profiles")
            .select("id, username")
            .in("id", values: ids)
            .execute()
            .value) ?? []
    }
}

import SwiftUI

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kAccent = Color(red: 0.62, green: 0.35, blue: 1.0)

private struct PendingRequest: Decodable, Identifiable {
    let followerId: UUID
    var id: UUID { followerId }

    enum CodingKeys: String, CodingKey {
        case followerId = "follower_id"
    }
}

struct FollowRequestsView: View {
    @Environment(AuthStore.self) private var authStore
    @State private var requests: [PendingRequest] = []
    @State private var usernames: [UUID: String] = [:]
    @State private var isLoading = false

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()
            if isLoading && requests.isEmpty {
                ProgressView().tint(kAccent)
            } else if requests.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 44)).foregroundStyle(Color(white: 0.38))
                    Text("No pending requests")
                        .foregroundStyle(.white).font(.headline)
                }
            } else {
                List {
                    ForEach(requests) { request in
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 32)).foregroundStyle(kAccent)
                            Text("@\(usernames[request.followerId] ?? "…")")
                                .foregroundStyle(.white).fontWeight(.medium)
                            Spacer()
                            Button("Accept") { Task { await respond(to: request, accept: true) } }
                                .buttonStyle(.borderedProminent).tint(kAccent)
                            Button("Decline") { Task { await respond(to: request, accept: false) } }
                                .buttonStyle(.bordered).tint(.red)
                        }
                        .listRowBackground(kBg)
                    }
                }
                .listStyle(.plain)
                .background(kBg)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Follow Requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        guard let myId = authStore.currentUserId else { return }
        isLoading = true
        defer { isLoading = false }

        requests = (try? await supabase
            .from("follows")
            .select("follower_id")
            .eq("following_id", value: myId)
            .eq("status", value: "pending")
            .execute()
            .value) ?? []

        struct ProfileRow: Decodable { let id: UUID; let username: String }
        guard !requests.isEmpty else { return }
        let profiles: [ProfileRow] = (try? await supabase
            .from("profiles")
            .select("id, username")
            .in("id", values: requests.map(\.followerId))
            .execute()
            .value) ?? []
        usernames = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.username) })
    }

    private func respond(to request: PendingRequest, accept: Bool) async {
        guard let myId = authStore.currentUserId else { return }
        do {
            if accept {
                try await supabase.from("follows")
                    .update(["status": "accepted"])
                    .eq("follower_id", value: request.followerId)
                    .eq("following_id", value: myId)
                    .execute()
            } else {
                try await supabase.from("follows")
                    .delete()
                    .eq("follower_id", value: request.followerId)
                    .eq("following_id", value: myId)
                    .execute()
            }
            requests.removeAll { $0.id == request.id }
        } catch {}
    }
}

import SwiftUI

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kTertiary = Color(white: 0.38)
private let kAccent = Color(red: 0.62, green: 0.35, blue: 1.0)

private enum FollowState: Equatable {
    case notFollowing, pending, accepted
}

struct UserProfileView: View {
    let userId: UUID

    @Environment(AuthStore.self) private var authStore
    @Environment(SavedStore.self) private var savedStore

    @State private var username: String?
    @State private var avatarUrl: String?
    @State private var followState: FollowState = .notFollowing
    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var savedClasses: [DanceClass] = []
    @State private var logEntries: [LogEntry] = []
    @State private var isLoading = false
    @State private var isUpdatingFollow = false

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    statsRow.padding(.horizontal, 16).padding(.top, 16)
                    followButton.padding(.horizontal, 16).padding(.top, 16)

                    if followState == .accepted {
                        if isLoading {
                            ProgressView().tint(kAccent).padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        } else {
                            content
                        }
                    } else {
                        lockedPlaceholder
                    }
                }
            }
        }
        .navigationTitle(username.map { "@\($0)" } ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(for: DanceClass.self) { cls in
            ClassDetailView(cls: cls)
        }
        .task { await loadAll() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Group {
                if let urlString = avatarUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(kAccent)
                        }
                    }
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(kAccent)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            statTile(count: followerCount, label: "Followers")
            statTile(count: followingCount, label: "Following")
        }
    }

    private func statTile(count: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.headline).foregroundStyle(.white)
            Text(label).font(.caption).foregroundStyle(kSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var followButton: some View {
        Button {
            Task { await toggleFollow() }
        } label: {
            HStack {
                if isUpdatingFollow { ProgressView().tint(followState == .notFollowing ? .white : kAccent) }
                Text(followButtonTitle)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(followState == .notFollowing ? kAccent : Color(white: 0.14))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isUpdatingFollow)
    }

    private var followButtonTitle: String {
        switch followState {
        case .notFollowing: return "Follow"
        case .pending: return "Requested"
        case .accepted: return "Following"
        }
    }

    private var lockedPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 36)).foregroundStyle(kTertiary)
            Text(followState == .pending ? "Follow request sent" : "Follow to see their classes")
                .font(.headline).foregroundStyle(.white)
            Text("Saved and logged classes are only visible to accepted followers.")
                .font(.caption).foregroundStyle(kSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private var content: some View {
        if !savedClasses.isEmpty {
            sectionHeader("Saved Classes")
            VStack(spacing: 8) {
                ForEach(savedClasses) { cls in
                    NavigationLink(value: cls) {
                        DarkClassRow(cls: cls, isShared: savedStore.savedIds.contains(cls.id.uuidString))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }

        if !logEntries.isEmpty {
            sectionHeader("Committed Classes")
            VStack(spacing: 8) {
                ForEach(logEntries) { entry in
                    LogEntryRow(entry: entry, isShared: savedStore.logEntries.contains { $0.isSameSession(as: entry) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }

        if savedClasses.isEmpty && logEntries.isEmpty {
            Text("No saved or logged classes yet.")
                .font(.subheadline).foregroundStyle(kSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(kSecondary)
            .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 8)
    }

    private func loadAll() async {
        guard let myId = authStore.currentUserId else { return }

        struct ProfileRow: Decodable { let username: String; let avatarUrl: String?
            enum CodingKeys: String, CodingKey { case username; case avatarUrl = "avatar_url" }
        }
        let profile: ProfileRow? = try? await supabase
            .from("profiles")
            .select("username, avatar_url")
            .eq("id", value: userId)
            .single()
            .execute()
            .value
        username = profile?.username
        avatarUrl = profile?.avatarUrl

        async let followers = countFollows(where: "following_id", equals: userId, status: "accepted")
        async let following = countFollows(where: "follower_id", equals: userId, status: "accepted")
        followerCount = await followers
        followingCount = await following

        struct FollowRow: Decodable { let status: String }
        let mine: [FollowRow] = (try? await supabase
            .from("follows")
            .select("status")
            .eq("follower_id", value: myId)
            .eq("following_id", value: userId)
            .execute()
            .value) ?? []
        followState = mine.first.map { $0.status == "accepted" ? .accepted : .pending } ?? .notFollowing

        if followState == .accepted {
            await fetchTheirClasses()
        }
    }

    private func fetchTheirClasses() async {
        isLoading = true
        defer { isLoading = false }

        struct SavedClassEmbed: Decodable { let classes: DanceClass }
        let savedRows: [SavedClassEmbed] = (try? await supabase
            .from("saved_classes")
            .select("classes(*, studios(name, schedule_urls), locations(name, address, city))")
            .eq("user_id", value: userId)
            .execute()
            .value) ?? []
        savedClasses = savedRows.map(\.classes).sorted { $0.date == $1.date ? $0.startTime < $1.startTime : $0.date < $1.date }

        let cloudEntries: [CloudLogEntry] = (try? await supabase
            .from("log_entries")
            .select("*")
            .eq("user_id", value: userId)
            .order("date", ascending: false)
            .execute()
            .value) ?? []
        logEntries = cloudEntries.map(\.asLogEntry)
    }

    private func countFollows(where column: String, equals userId: UUID, status: String) async -> Int {
        (try? await supabase
            .from("follows")
            .select("*", head: true, count: .exact)
            .eq(column, value: userId)
            .eq("status", value: status)
            .execute()
            .count) ?? 0
    }

    private func toggleFollow() async {
        guard let myId = authStore.currentUserId else { return }
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }

        do {
            switch followState {
            case .notFollowing:
                try await supabase.from("follows")
                    .insert(["follower_id": myId.uuidString, "following_id": userId.uuidString])
                    .execute()
                followState = .pending
            case .pending, .accepted:
                try await supabase.from("follows")
                    .delete()
                    .eq("follower_id", value: myId)
                    .eq("following_id", value: userId)
                    .execute()
                followState = .notFollowing
                savedClasses = []
                logEntries = []
            }
        } catch {}
    }
}

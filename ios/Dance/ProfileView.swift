import SwiftUI
import PhotosUI
import UIKit

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kTertiary = Color(white: 0.38)
private let kAccent = Color(red: 0.62, green: 0.35, blue: 1.0)

struct ProfileView: View {
    @Environment(AuthStore.self) private var authStore
    @Environment(SavedStore.self) private var savedStore

    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var pendingRequestCount = 0
    @State private var savedClasses: [DanceClass] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showLogSheet = false
    @State private var selectedEntry: LogEntry?
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var followListKind: FollowListView.Kind?
    @State private var isUploadingAvatar = false
    @State private var localAvatarImage: UIImage?

    // "My Class Log" is for classes you're committed to attending, not a history —
    // once a logged class's date passes, it drops out of this list.
    private var upcomingLogEntries: [LogEntry] {
        savedStore.logEntries.filter { $0.date >= Date() }
    }

    var body: some View {
        List {
            Group {
                header
                statsRow.padding(.top, 16)
                NavRow(destination: FollowRequestsView()) {
                    rowLabel(icon: "person.crop.circle.badge.clock", title: "Follow Requests", badge: pendingRequestCount)
                }
                .padding(.top, 16)
                NavRow(destination: UserSearchView()) {
                    rowLabel(icon: "magnifyingglass", title: "Find Friends", badge: 0)
                }
            }
            .listRowBackground(kBg)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            if (isLoading || savedStore.isLoading) && savedClasses.isEmpty && savedStore.savedIds.isEmpty {
                loadingRow
            } else if let err = error, savedClasses.isEmpty {
                DarkErrorView(message: err) { Task { await loadAll() } }
                    .listRowBackground(kBg)
                    .listRowSeparator(.hidden)
            }

            if !savedClasses.isEmpty {
                Section(header: sectionHeader("Saved Classes")) {
                    ForEach(savedClasses) { cls in
                        NavigationLink(value: cls) {
                            DarkClassRow(cls: cls, isSaved: true, showDate: true)
                        }
                        .listRowBackground(kBg)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            // The first action is outermost (closest to the screen edge) and
                            // is what a full swipe triggers; later actions sit further left,
                            // closer to the content, and need an explicit tap.
                            Button(role: .destructive) {
                                savedStore.toggle(cls.id)
                            } label: {
                                Label("Delete", systemImage: "xmark")
                            }

                            Button {
                                savedStore.addLog(logEntry(from: cls))
                            } label: {
                                Label("Commit", systemImage: "checkmark.circle")
                            }
                            .tint(.green)
                        }
                    }
                }
            }

            Section(header: committedClassesHeader) {
                if upcomingLogEntries.isEmpty {
                    Text("No committed classes yet")
                        .font(.subheadline).foregroundStyle(kSecondary)
                        .padding(.vertical, 8)
                        .listRowBackground(kBg)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(upcomingLogEntries) { entry in
                        Button { selectedEntry = entry } label: {
                            LogEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(kBg)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                savedStore.deleteLog(id: entry.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Button {
                Task { try? await authStore.signOut() }
            } label: {
                Text("Sign Out")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .listRowBackground(kBg)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 32, trailing: 16))
        }
        .listStyle(.plain)
        .background(kBg)
        .scrollContentBackground(.hidden)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showLogSheet) { LogEntrySheet() }
        .sheet(item: $selectedEntry) { entry in
            if entry.isManual {
                LogEntrySheet(existing: entry)
            } else {
                LogEntryDetailSheet(entry: entry)
            }
        }
        .navigationDestination(for: DanceClass.self) { cls in
            ClassDetailView(cls: cls)
        }
        .navigationDestination(item: $followListKind) { kind in
            FollowListView(userId: authStore.currentUserId, kind: kind)
        }
        .task { await loadAll() }
        .task(id: savedStore.savedIds) { await fetchSavedClasses() }
        .refreshable { await loadAll() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                ZStack {
                    avatarImage
                    if isUploadingAvatar {
                        Circle().fill(Color.black.opacity(0.5))
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: 64, height: 64)
                .overlay(alignment: .bottomTrailing) {
                    if !isUploadingAvatar {
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, kAccent)
                            .background(Circle().fill(kBg).padding(1))
                    }
                }
            }
            .buttonStyle(.plain)
            .onChange(of: avatarPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    isUploadingAvatar = true
                    defer { isUploadingAvatar = false; avatarPickerItem = nil }
                    do {
                        guard let data = try await newItem.loadTransferable(type: Data.self),
                              let uiImage = UIImage(data: data) else { return }
                        // Show the pick instantly rather than waiting on the network
                        // round-trip; the spinner overlay still indicates the save itself.
                        localAvatarImage = uiImage
                        guard let uploadData = uiImage.resizedForAvatar().jpegData(compressionQuality: 0.8) else { return }
                        try await authStore.updateAvatar(imageData: uploadData)
                    } catch {
                        print("ProfileView avatar upload failed: \(error)")
                    }
                }
            }

            Text("@\(authStore.username ?? "")")
                .font(.title3).fontWeight(.bold)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    @ViewBuilder
    private var avatarImage: some View {
        Group {
            if let localAvatarImage {
                Image(uiImage: localAvatarImage).resizable().scaledToFill()
            } else if let urlString = authStore.avatarUrl, let url = URL(string: urlString) {
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

    private var loadingRow: some View {
        ProgressView("Loading…")
            .tint(kAccent)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(kBg)
            .listRowSeparator(.hidden)
    }

    // Two NavigationLinks sharing one List row (even NavRow's invisible ones)
    // confuses List's row-tap-activates-its-NavigationLink behavior — it doesn't
    // reliably pick the one matching where you actually tapped. Plain buttons
    // driving .navigationDestination(item:) below sidestep that entirely, since
    // it's not List-row-activation-based at all.
    private var statsRow: some View {
        HStack(spacing: 12) {
            Button { followListKind = .followers } label: {
                statTile(count: followerCount, label: "Followers")
            }
            .buttonStyle(.plain)
            Button { followListKind = .following } label: {
                statTile(count: followingCount, label: "Following")
            }
            .buttonStyle(.plain)
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

    private func rowLabel(icon: String, title: String, badge: Int) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(kAccent).frame(width: 22)
            Text(title).foregroundStyle(.white)
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(kAccent)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 12)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(kSecondary)
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
    }

    private var committedClassesHeader: some View {
        HStack {
            Text("Committed Classes")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(kSecondary)
            Spacer()
            Button {
                showLogSheet = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(kAccent)
            }
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
    }

    private func logEntry(from cls: DanceClass) -> LogEntry {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "America/Los_Angeles")
        let date = fmt.date(from: "\(cls.date) \(cls.startTime)") ?? Date()
        return LogEntry(
            date: date,
            duration: cls.durationMinutes ?? 60,
            title: cls.title,
            danceStyle: cls.danceStyle ?? "",
            level: cls.level ?? "all_levels",
            instructor: cls.instructor ?? "",
            studio: cls.studios?.name ?? "",
            notes: "",
            sourceClassId: cls.id.uuidString
        )
    }

    private func loadAll() async {
        guard let userId = authStore.currentUserId else { return }
        isLoading = true
        async let followers = countFollows(where: "following_id", equals: userId, status: "accepted")
        async let following = countFollows(where: "follower_id", equals: userId, status: "accepted")
        async let pending = countFollows(where: "following_id", equals: userId, status: "pending")
        followerCount = await followers
        followingCount = await following
        pendingRequestCount = await pending
        isLoading = false
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

    private func fetchSavedClasses() async {
        guard !savedStore.savedIds.isEmpty else { savedClasses = []; return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        do {
            savedClasses = try await supabase
                .from("classes")
                .select("*, studios(name, schedule_urls), locations(name, address, city)")
                .in("id", values: Array(savedStore.savedIds))
                .gte("date", value: today)
                .order("date", ascending: true)
                .order("start_time", ascending: true)
                .execute()
                .value
            error = nil
            savedStore.pruneSaved(keeping: Set(savedClasses.map { $0.id.uuidString }))
        } catch {
            self.error = error.localizedDescription
            print("ProfileView.fetchSavedClasses failed: \(error)")
        }
    }
}

/// A NavigationLink whose destination is reachable by tapping `content`, without
/// List rendering its own disclosure chevron. List adds that chevron automatically
/// to any row built from `NavigationLink { destination } label: { ... }` — this
/// keeps the tap target while presenting as plain, non-NavigationLink content.
private struct NavRow<Destination: View, RowContent: View>: View {
    let destination: Destination
    @ViewBuilder let content: () -> RowContent

    var body: some View {
        ZStack {
            content()
            NavigationLink(destination: destination) { EmptyView() }
                .opacity(0)
        }
    }
}

private extension UIImage {
    /// Downscales to a max dimension before upload — an original photo can be
    /// several MB, which is what actually made the upload slow, not just the UI.
    func resizedForAvatar(maxDimension: CGFloat = 512) -> UIImage {
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

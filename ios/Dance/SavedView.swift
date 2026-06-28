import SwiftUI

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kTertiary = Color(white: 0.38)

struct SavedView: View {
    @Environment(SavedStore.self) private var savedStore
    @State private var classes: [DanceClass] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()

            if isLoading && classes.isEmpty {
                ProgressView("Loading…")
                    .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
                    .foregroundStyle(.white)
            } else if savedStore.savedIds.isEmpty {
                emptyState
            } else if let err = error, classes.isEmpty {
                DarkErrorView(message: err) { Task { await fetch() } }
            } else if classes.isEmpty && !isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 44)).foregroundStyle(kTertiary)
                    Text("No upcoming saved classes")
                        .foregroundStyle(.white).font(.headline)
                    Text("Saved classes that have passed won't show here.")
                        .foregroundStyle(kSecondary).font(.caption)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
            } else {
                classList
            }
        }
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: savedStore.savedIds) { await fetch() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart")
                .font(.system(size: 52))
                .foregroundStyle(Color(red: 0.62, green: 0.35, blue: 1.0))
            Text("No saved classes yet")
                .font(.title3).fontWeight(.semibold).foregroundStyle(.white)
            Text("Tap the heart on any class to save it here.")
                .foregroundStyle(kSecondary).multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var classList: some View {
        let grouped = Dictionary(grouping: classes, by: \.date)
        let sections = grouped.sorted { $0.key < $1.key }.map { (date: $0.key, label: $0.key.dateLabel, classes: $0.value.sorted { $0.startTime < $1.startTime }) }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(sections, id: \.date) { section in
                    Section {
                        ForEach(section.classes) { cls in
                            NavigationLink(value: cls) {
                                DarkClassRow(cls: cls, isSaved: true) {
                                    savedStore.toggle(cls.id)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text(section.label)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(kSecondary)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(kBg)
                    }
                }
                Spacer().frame(height: 24)
            }
        }
        .background(kBg)
        .refreshable { await fetch() }
        .navigationDestination(for: DanceClass.self) { cls in
            ClassDetailView(cls: cls)
        }
    }

    private func fetch() async {
        guard !savedStore.savedIds.isEmpty else { classes = []; return }
        isLoading = true
        error = nil
        do {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let today = fmt.string(from: Date())

            classes = try await supabase
                .from("classes")
                .select("*, studios(name, schedule_urls), locations(name, address, city)")
                .in("id", values: Array(savedStore.savedIds))
                .gte("date", value: today)
                .order("date", ascending: true)
                .order("start_time", ascending: true)
                .execute()
                .value
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

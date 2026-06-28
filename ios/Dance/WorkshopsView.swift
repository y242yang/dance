import SwiftUI

private let kBg = Color.black
private let kCardBg = Color(white: 0.10)
private let kSecondary = Color(white: 0.52)
private let kTertiary = Color(white: 0.38)

@Observable
final class WorkshopsViewModel {
    var classes: [DanceClass] = []
    var isLoading = false
    var error: String?
    var selectedStudio: String? = nil

    var availableStudios: [String] {
        Array(Set(classes.compactMap { $0.studios?.name }.filter { !$0.isEmpty })).sorted()
    }

    var filtered: [DanceClass] {
        guard let studio = selectedStudio else { return classes }
        return classes.filter { $0.studios?.name == studio }
    }

    // Group by studio name then by workshop title (deduplicated series)
    var workshopsByStudio: [(studio: String, workshops: [WorkshopSeries])] {
        let byStudio = Dictionary(grouping: filtered) { $0.studios?.name ?? "Unknown" }
        return byStudio.keys.sorted().map { studio in
            let studioClasses = byStudio[studio] ?? []
            // Group sessions of the same workshop by title
            let byTitle = Dictionary(grouping: studioClasses, by: \.title)
            let series = byTitle.keys.sorted().map { title in
                let first = byTitle[title]!.first!
                return WorkshopSeries(
                    id: "\(studio)|\(title)",
                    title: title,
                    studioName: studio,
                    scheduleUrl: first.studios?.scheduleUrl,
                    level: first.level,
                    danceStyle: first.danceStyle,
                    styleColor: first.styleColor ?? .indigo
                )
            }
            return (studio: studio, workshops: series)
        }
    }

    @MainActor
    func fetch() async {
        isLoading = true
        error = nil
        do {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let today = fmt.string(from: Date())
            let cutoff = fmt.string(from: Calendar.current.date(byAdding: .day, value: 14, to: Date())!)

            classes = try await supabase
                .from("classes")
                .select("*, studios(name, schedule_urls), locations(name, address, city)")
                .eq("is_workshop", value: true)
                .gte("date", value: today)
                .lte("date", value: cutoff)
                .order("date", ascending: true)
                .execute()
                .value
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

struct WorkshopSeries: Identifiable {
    let id: String
    let title: String
    let studioName: String
    let scheduleUrl: String?
    let level: String?
    let danceStyle: String?
    let styleColor: Color
}

// MARK: - Workshops View

struct WorkshopsView: View {
    @State private var viewModel = WorkshopsViewModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()

            if viewModel.isLoading && viewModel.classes.isEmpty {
                ProgressView("Loading workshops…")
                    .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
                    .foregroundStyle(.white)
            } else if let err = viewModel.error, viewModel.classes.isEmpty {
                DarkErrorView(message: err) { Task { await viewModel.fetch() } }
            } else if viewModel.classes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 40)).foregroundStyle(kTertiary)
                    Text("No workshops in the next 2 weeks")
                        .foregroundStyle(.white).font(.headline)
                }
            } else {
                VStack(spacing: 0) {
                    studioFilterBar
                        .padding(.vertical, 10)
                        .background(kBg)

                    Divider().overlay(Color(white: 0.18))

                    if viewModel.workshopsByStudio.isEmpty {
                        ZStack {
                            kBg
                            Text("No workshops for this studio")
                                .foregroundStyle(kSecondary)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(viewModel.workshopsByStudio, id: \.studio) { group in
                                    Section {
                                        ForEach(group.workshops) { workshop in
                                            WorkshopCard(workshop: workshop)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 4)
                                        }
                                    } header: {
                                        Text(group.studio)
                                            .font(.subheadline).fontWeight(.semibold)
                                            .foregroundStyle(kSecondary)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(kBg)
                                    }
                                }
                                Spacer().frame(height: 24)
                            }
                        }
                        .background(kBg)
                        .refreshable { await viewModel.fetch() }
                    }
                }
            }
        }
        .navigationTitle("Workshops")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await viewModel.fetch() }
    }

    private var studioFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                DarkChip(label: "All Studios", isSelected: viewModel.selectedStudio == nil,
                         color: Color(red: 0.62, green: 0.35, blue: 1.0)) {
                    viewModel.selectedStudio = nil
                }
                ForEach(viewModel.availableStudios, id: \.self) { studio in
                    DarkChip(label: studio, isSelected: viewModel.selectedStudio == studio,
                             color: Color(red: 0.62, green: 0.35, blue: 1.0)) {
                        viewModel.selectedStudio = viewModel.selectedStudio == studio ? nil : studio
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Workshop Card

struct WorkshopCard: View {
    let workshop: WorkshopSeries
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let urlStr = workshop.scheduleUrl, let url = URL(string: urlStr) else { return }
            openURL(url)
        } label: {
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(workshop.styleColor)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(workshop.title)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(kTertiary)
                    }

                    HStack(spacing: 6) {
                        if let style = workshop.danceStyle, !style.isEmpty {
                            Text(style).font(.caption).foregroundStyle(workshop.styleColor)
                        }
                        if let level = workshop.level {
                            Text("·").font(.caption).foregroundStyle(kTertiary)
                            Text(level.levelDisplayName)
                                .font(.caption).foregroundStyle(kSecondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
            .background(kCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

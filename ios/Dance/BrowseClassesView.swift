import SwiftUI

enum BrowseFilter {
    case style, level, date
}

private let kBg = Color.black
private let kCardBg = Color(white: 0.10)
private let kSecondary = Color(white: 0.52)
private let kTertiary = Color(white: 0.38)

@Observable
final class BrowseClassesViewModel {
    var classes: [DanceClass] = []
    var isLoading = false
    var error: String?
    var selected: String? = nil

    func chips(for mode: BrowseFilter) -> [String] {
        switch mode {
        case .style:
            return Array(Set(classes.compactMap { $0.danceStyle }.filter { !$0.isEmpty })).sorted()
        case .level:
            let order = ["beginner", "begin/int", "intermediate", "int/adv", "advanced", "all_levels"]
            let found = Set(classes.compactMap { $0.level }.filter { !$0.isEmpty })
            return order.filter { found.contains($0) }
        case .date:
            return Array(Set(classes.map { $0.date })).sorted()
        }
    }

    func filtered(for mode: BrowseFilter) -> [DanceClass] {
        guard let sel = selected else { return classes }
        switch mode {
        case .style: return classes.filter { $0.danceStyle == sel }
        case .level: return classes.filter { $0.level == sel }
        case .date:  return classes.filter { $0.date == sel }
        }
    }

    var classesByDate: [(date: String, label: String, classes: [DanceClass])] {
        let grouped = Dictionary(grouping: classes, by: \.date)
        return grouped.sorted { $0.key < $1.key }
            .map { (date, cls) in (date: date, label: date.dateLabel,
                                   classes: cls.sorted { $0.startTime < $1.startTime }) }
    }

    func filteredByDate(for mode: BrowseFilter) -> [(date: String, label: String, classes: [DanceClass])] {
        let src = filtered(for: mode)
        let grouped = Dictionary(grouping: src, by: \.date)
        return grouped.sorted { $0.key < $1.key }
            .map { (date, cls) in (date: date, label: date.dateLabel,
                                   classes: cls.sorted { $0.startTime < $1.startTime }) }
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
                .gte("date", value: today)
                .lte("date", value: cutoff)
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

struct BrowseClassesView: View {
    let mode: BrowseFilter
    @State private var viewModel = BrowseClassesViewModel()
    @Environment(SavedStore.self) private var savedStore

    var title: String {
        switch mode {
        case .style: return "Dance Style"
        case .level: return "Level"
        case .date:  return "Date"
        }
    }

    var chipColor: Color {
        switch mode {
        case .style: return .pink
        case .level: return .orange
        case .date:  return Color(red: 0.62, green: 0.35, blue: 1.0)
        }
    }

    func chipLabel(_ chip: String) -> String {
        switch mode {
        case .level: return chip.levelDisplayName
        case .date:  return chip.dateLabel
        default:     return chip
        }
    }

    func chipColor(for chip: String) -> Color {
        switch mode {
        case .style: return DanceClass(id: UUID(), title: "", danceStyle: chip,
                                       instructor: nil, level: nil, date: "", startTime: "",
                                       durationMinutes: nil, description: nil,
                                       studios: nil, locations: nil).styleColor
        case .level: return chip.levelColor
        case .date:  return chipColor
        }
    }

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()

            if viewModel.isLoading && viewModel.classes.isEmpty {
                ProgressView("Loading…")
                    .tint(chipColor).foregroundStyle(.white)
            } else if let err = viewModel.error, viewModel.classes.isEmpty {
                DarkErrorView(message: err) { Task { await viewModel.fetch() } }
            } else {
                VStack(spacing: 0) {
                    if mode == .date {
                        dateDropdown
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(kBg)
                    } else {
                        chipBar
                            .padding(.vertical, 10)
                            .background(kBg)
                    }

                    Divider().overlay(Color(white: 0.18))

                    let sections = viewModel.filteredByDate(for: mode)
                    if sections.isEmpty {
                        ZStack {
                            kBg
                            VStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 40)).foregroundStyle(kTertiary)
                                Text("No classes found").foregroundStyle(.white).font(.headline)
                            }
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(sections, id: \.date) { section in
                                    Section {
                                        ForEach(section.classes) { cls in
                                            NavigationLink(value: cls) {
                                                DarkClassRow(cls: cls,
                                                    isSaved: savedStore.isSaved(cls.id),
                                                    onToggleSave: { savedStore.toggle(cls.id) })
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
                        .refreshable { await viewModel.fetch() }
                    }
                }
                .navigationDestination(for: DanceClass.self) { cls in
                    ClassDetailView(cls: cls)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await viewModel.fetch() }
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                DarkChip(label: "All", isSelected: viewModel.selected == nil,
                         color: chipColor) { viewModel.selected = nil }
                ForEach(viewModel.chips(for: mode), id: \.self) { chip in
                    DarkChip(label: chipLabel(chip),
                             isSelected: viewModel.selected == chip,
                             color: chipColor(for: chip)) {
                        viewModel.selected = viewModel.selected == chip ? nil : chip
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var dateDropdown: some View {
        Menu {
            Button("All Dates") { viewModel.selected = nil }
            ForEach(viewModel.chips(for: .date), id: \.self) { date in
                Button(date.dateLabel) { viewModel.selected = date }
            }
        } label: {
            HStack {
                Image(systemName: "calendar")
                Text(viewModel.selected.map { $0.dateLabel } ?? "All Dates")
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(white: 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(white: 0.22), lineWidth: 1))
        }
    }
}

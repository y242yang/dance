import SwiftUI

private let kCardBg = Color(white: 0.10)
private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kTertiary = Color(white: 0.38)

struct ClassListView: View {
    @State private var viewModel = DanceViewModel()
    @Environment(SavedStore.self) private var savedStore
    @Environment(AuthStore.self) private var authStore

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()
            Group {
                if viewModel.isLoading && viewModel.classes.isEmpty {
                    ProgressView("Loading classes…")
                        .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = viewModel.error, viewModel.classes.isEmpty {
                    DarkErrorView(message: err) {
                        Task { await viewModel.fetch() }
                    }
                } else {
                    classListContent
                }
            }
        }
        .navigationTitle("Classes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(for: DanceClass.self) { cls in
            ClassDetailView(cls: cls)
        }
        .task { await viewModel.fetch() }
    }

    @ViewBuilder
    private var classListContent: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 0) {
            DarkFilterBar(viewModel: viewModel)
                .padding(.vertical, 10)
                .background(kBg)

            Divider().overlay(Color(white: 0.18))

            if viewModel.classesByDate.isEmpty {
                ZStack {
                    kBg
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(kTertiary)
                        Text("No classes found")
                            .foregroundStyle(.white).font(.headline)
                        Text("Try adjusting your filters.")
                            .foregroundStyle(kSecondary)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(viewModel.classesByDate, id: \.date) { section in
                            Section {
                                ForEach(section.classes) { cls in
                                    NavigationLink(value: cls) {
                                        DarkClassRow(cls: cls,
                                            isSaved: savedStore.isSaved(cls.id),
                                            onToggleSave: authStore.isSignedIn ? { savedStore.toggle(cls.id) } : nil)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 4)
                                }
                            } header: {
                                Text(section.label)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
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
        .searchable(text: $vm.searchText, prompt: "Classes, instructors, studios…")
        .searchBarStyle(dark: true)
    }
}

// MARK: - Dark Filter Bar

struct DarkFilterBar: View {
    @Bindable var viewModel: DanceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Style chips
            if !viewModel.availableStyles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        DarkChip(label: "All Styles", isSelected: viewModel.selectedStyle == nil,
                                 color: .pink) { viewModel.selectedStyle = nil }
                        ForEach(viewModel.availableStyles, id: \.self) { style in
                            let color = DanceClass(id: UUID(), title: "", danceStyle: style,
                                instructor: nil, level: nil, date: "", startTime: "",
                                durationMinutes: nil, description: nil,
                                studios: nil, locations: nil).styleColor
                            DarkChip(label: style, isSelected: viewModel.selectedStyle == style,
                                     color: color) {
                                viewModel.selectedStyle = viewModel.selectedStyle == style ? nil : style
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Level chips
            if !viewModel.availableLevels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        DarkChip(label: "All Levels", isSelected: viewModel.selectedLevel == nil,
                                 color: .orange) { viewModel.selectedLevel = nil }
                        ForEach(viewModel.availableLevels, id: \.self) { level in
                            DarkChip(label: level.levelDisplayName,
                                     isSelected: viewModel.selectedLevel == level,
                                     color: level.levelColor) {
                                viewModel.selectedLevel = viewModel.selectedLevel == level ? nil : level
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Date / Location / Studio dropdowns
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Date
                    FilterDropdown(
                        icon: "calendar",
                        label: viewModel.selectedDate.map { $0.dateLabel } ?? "Date",
                        isActive: viewModel.selectedDate != nil,
                        labelWidth: 70
                    ) {
                        Button("All Dates") { viewModel.selectedDate = nil }
                        ForEach(viewModel.availableDates, id: \.self) { d in
                            Button(d.dateLabel) { viewModel.selectedDate = d }
                        }
                    }

                    // Location
                    FilterDropdown(
                        icon: "mappin",
                        label: viewModel.selectedCity ?? "Location",
                        isActive: viewModel.selectedCity != nil,
                        labelWidth: 85
                    ) {
                        Button("All Locations") { viewModel.selectedCity = nil }
                        ForEach(viewModel.availableCities, id: \.self) { city in
                            Button(city) { viewModel.selectedCity = city }
                        }
                    }

                    // Studio
                    FilterDropdown(
                        icon: "building.2",
                        label: viewModel.selectedStudio ?? "Studio",
                        isActive: viewModel.selectedStudio != nil,
                        labelWidth: 100
                    ) {
                        Button("All Studios") { viewModel.selectedStudio = nil }
                        ForEach(viewModel.availableStudios, id: \.self) { studio in
                            Button(studio) { viewModel.selectedStudio = studio }
                        }
                    }

                    // Clear all
                    if viewModel.activeFilterCount > 0 {
                        Button {
                            viewModel.clearFilters()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark")
                                Text("Clear")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(white: 0.2))
                            .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct FilterDropdown<Content: View>: View {
    let icon: String
    let label: String
    let isActive: Bool
    var labelWidth: CGFloat = 100
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).imageScale(.small)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: labelWidth, alignment: .leading)
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(.subheadline)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isActive ? Color(red: 0.62, green: 0.35, blue: 1.0) : Color(white: 0.14))
            .clipShape(Capsule())
        }
    }
}

struct DarkChip: View {
    let label: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? color : Color(white: 0.14))
                .foregroundStyle(isSelected ? .white : Color(white: 0.72))
                .clipShape(Capsule())
        }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Dark Class Row

struct DarkClassRow: View {
    let cls: DanceClass
    var isSaved: Bool = false
    var isShared: Bool = false
    var showDate: Bool = false
    var onToggleSave: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(cls.styleColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    Text(cls.title)
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer()
                    if isShared {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.62, green: 0.35, blue: 1.0))
                            .help("You've both done this class")
                    }
                    if let level = cls.level {
                        Text(level.levelDisplayName)
                            .font(.caption2).fontWeight(.medium)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(level.levelColor.opacity(0.18))
                            .foregroundStyle(level.levelColor)
                            .clipShape(Capsule())
                    }
                    if let toggle = onToggleSave {
                        Button {
                            toggle()
                        } label: {
                            Image(systemName: isSaved ? "heart.fill" : "heart")
                                .foregroundStyle(isSaved ? Color.pink : Color(white: 0.45))
                                .font(.system(size: 15))
                                .padding(.leading, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let instructor = cls.instructor, !instructor.isEmpty {
                    Text("w/ \(instructor)")
                        .font(.caption)
                        .foregroundStyle(kSecondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: showDate ? "calendar" : "clock").imageScale(.small)
                    if showDate {
                        Text(cls.date.dateLabel + " ·")
                    }
                    Text(cls.formattedTime)
                    if let dur = cls.durationMinutes { Text("· \(dur) min") }
                }
                .font(.caption)
                .foregroundStyle(kTertiary)

                HStack {
                    if let style = cls.danceStyle, !style.isEmpty {
                        Text(style).font(.caption).foregroundStyle(cls.styleColor)
                    }
                    Spacer()
                    if let studio = cls.studios?.name {
                        Text(studio).font(.caption).foregroundStyle(kTertiary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
        }
        .background(kCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Error View

struct DarkErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48)).foregroundStyle(.orange)
            Text("Could not load classes").font(.headline).foregroundStyle(.white)
            Text(message).font(.caption).foregroundStyle(kSecondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Try Again", action: retry).buttonStyle(.borderedProminent)
                .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(kBg)
    }
}

// MARK: - Search bar dark styling helper

private extension View {
    func searchBarStyle(dark: Bool) -> some View {
        self
    }
}

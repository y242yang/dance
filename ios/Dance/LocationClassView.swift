import SwiftUI

struct LocationClassView: View {
    @State private var viewModel = DanceViewModel()
    @State private var selectedCity: String? = nil

    private var availableCities: [String] {
        Array(Set(viewModel.classes.compactMap { $0.locations?.city }.filter { !$0.isEmpty })).sorted()
    }

    private var filteredClasses: [DanceClass] {
        guard let city = selectedCity else { return viewModel.filteredClasses }
        return viewModel.filteredClasses.filter {
            $0.locations?.city?.lowercased() == city.lowercased()
        }
    }

    private var classesByDate: [(date: String, label: String, classes: [DanceClass])] {
        let grouped = Dictionary(grouping: filteredClasses, by: \.date)
        return grouped.sorted { $0.key < $1.key }
            .map { (date, classes) in
                (date: date,
                 label: date.dateLabel,
                 classes: classes.sorted { $0.startTime < $1.startTime })
            }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading && viewModel.classes.isEmpty {
                ProgressView("Loading classes…")
                    .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
                    .foregroundStyle(.white)
            } else if let err = viewModel.error, viewModel.classes.isEmpty {
                DarkErrorView(message: err) { Task { await viewModel.fetch() } }
            } else {
                VStack(spacing: 0) {
                    cityFilterBar
                        .padding(.vertical, 10)
                        .background(Color.black)

                    Divider().overlay(Color(white: 0.18))

                    if classesByDate.isEmpty {
                        ZStack {
                            Color.black
                            VStack(spacing: 12) {
                                Image(systemName: "mappin.slash")
                                    .font(.system(size: 40))
                                    .foregroundStyle(Color(white: 0.38))
                                Text("No classes in this location")
                                    .foregroundStyle(.white).font(.headline)
                            }
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(classesByDate, id: \.date) { section in
                                    Section {
                                        ForEach(section.classes) { cls in
                                            NavigationLink(value: cls) {
                                                DarkClassRow(cls: cls)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 4)
                                        }
                                    } header: {
                                        Text(section.label)
                                            .font(.subheadline).fontWeight(.semibold)
                                            .foregroundStyle(Color(white: 0.52))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.black)
                                    }
                                }
                                Spacer().frame(height: 24)
                            }
                        }
                        .background(Color.black)
                        .refreshable { await viewModel.fetch() }
                    }
                }
            }
        }
        .navigationTitle("By Location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(for: DanceClass.self) { cls in
            ClassDetailView(cls: cls)
        }
        .task { await viewModel.fetch() }
    }

    private var cityFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                DarkChip(label: "All Locations", isSelected: selectedCity == nil,
                         color: Color(red: 0.18, green: 0.70, blue: 0.45)) {
                    selectedCity = nil
                }
                ForEach(availableCities, id: \.self) { city in
                    DarkChip(label: city, isSelected: selectedCity == city,
                             color: Color(red: 0.18, green: 0.70, blue: 0.45)) {
                        selectedCity = selectedCity == city ? nil : city
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

import Foundation
import Observation

@Observable
final class DanceViewModel {
    var classes: [DanceClass] = []
    var isLoading = false
    var error: String?
    var searchText: String = ""

    var selectedStyle: String? = nil
    var selectedLevel: String? = nil
    var selectedDate: String? = nil
    var selectedCity: String? = nil
    var selectedStudio: String? = nil

    var activeFilterCount: Int {
        [selectedStyle, selectedLevel, selectedDate, selectedCity, selectedStudio]
            .compactMap { $0 }.count
    }

    var availableStyles: [String] {
        Array(Set(classes.compactMap(\.danceStyle).filter { !$0.isEmpty })).sorted()
    }

    var availableLevels: [String] {
        let order = ["beginner", "begin/int", "intermediate", "int/adv", "advanced", "master", "all_levels"]
        let found = Set(classes.compactMap(\.level).filter { !$0.isEmpty })
        return order.filter { found.contains($0) }
    }

    var availableDates: [String] {
        Array(Set(classes.map(\.date))).sorted()
    }

    var availableCities: [String] {
        Array(Set(classes.compactMap { $0.locations?.city }.filter { !$0.isEmpty })).sorted()
    }

    var availableStudios: [String] {
        Array(Set(classes.compactMap { $0.studios?.name }.filter { !$0.isEmpty })).sorted()
    }

    var filteredClasses: [DanceClass] {
        classes.filter { c in
            if let style = selectedStyle, c.danceStyle != style { return false }
            if let level = selectedLevel, c.level != level { return false }
            if let date = selectedDate, c.date != date { return false }
            if let city = selectedCity, c.locations?.city != city { return false }
            if let studio = selectedStudio, c.studios?.name != studio { return false }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let matches = c.title.lowercased().contains(q)
                    || (c.instructor?.lowercased().contains(q) ?? false)
                    || (c.danceStyle?.lowercased().contains(q) ?? false)
                    || (c.studios?.name.lowercased().contains(q) ?? false)
                if !matches { return false }
            }
            return true
        }
    }

    var classesByDate: [(date: String, label: String, classes: [DanceClass])] {
        let grouped = Dictionary(grouping: filteredClasses, by: \.date)
        return grouped
            .sorted { $0.key < $1.key }
            .map { (date, classes) in
                (date: date,
                 label: date.dateLabel,
                 classes: classes.sorted { $0.startTime < $1.startTime })
            }
    }

    func clearFilters() {
        selectedStyle = nil
        selectedLevel = nil
        selectedDate = nil
        selectedCity = nil
        selectedStudio = nil
    }

    @MainActor
    func fetch() async {
        isLoading = true
        error = nil
        do {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let today = fmt.string(from: Date())
            let cutoff = fmt.string(from: Calendar.current.date(byAdding: .day, value: scheduleDaysAhead, to: Date())!)

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

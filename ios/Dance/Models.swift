import SwiftUI
import Foundation

struct DanceClass: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let danceStyle: String?
    let instructor: String?
    let level: String?
    let date: String       // "YYYY-MM-DD"
    let startTime: String  // "HH:MM:SS"
    let durationMinutes: Int?
    let description: String?
    let studios: StudioInfo?
    let locations: LocationInfo?

    enum CodingKeys: String, CodingKey {
        case id, title, instructor, level, date, description
        case danceStyle = "dance_style"
        case startTime = "start_time"
        case durationMinutes = "duration_minutes"
        case studios, locations
    }

    var formattedTime: String {
        let parts = startTime.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return startTime }
        let ampm = hour >= 12 ? "PM" : "AM"
        let h12 = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour)
        let m = minute == 0 ? "" : ":\(String(format: "%02d", minute))"
        return "\(h12)\(m) \(ampm)"
    }

    // Keep the styles here in sync with the scraper's canonical _VALID_STYLES list
    // (scraper/scraper.py). More-specific matches must come before generic ones —
    // e.g. "jazz funk" contains "jazz", and "chinese fusion" contains "chinese".
    var styleColor: Color {
        guard let style = danceStyle?.lowercased() else { return .indigo }
        if style.contains("hip hop") || style.contains("hiphop") { return Color(red: 0.53, green: 0.22, blue: 0.90) }
        if style.contains("heels") { return Color(red: 0.92, green: 0.23, blue: 0.52) }
        if style.contains("jazz funk") || style.contains("jazzfunk") { return Color(red: 0.95, green: 0.42, blue: 0.30) }
        if style.contains("jazz") { return Color(red: 0.92, green: 0.52, blue: 0.18) }
        if style.contains("reggaeton") { return Color(red: 0.85, green: 0.45, blue: 0.10) }
        if style.contains("dancehall") { return Color(red: 0.95, green: 0.70, blue: 0.15) }
        if style.contains("salsa") || style.contains("latin") { return Color(red: 0.90, green: 0.32, blue: 0.18) }
        if style.contains("contemporary") || style.contains("modern") { return Color(red: 0.18, green: 0.70, blue: 0.68) }
        if style.contains("ballet") { return Color(red: 0.82, green: 0.30, blue: 0.62) }
        if style.contains("kpop") || style.contains("k-pop") { return Color(red: 0.42, green: 0.28, blue: 0.92) }
        if style.contains("waacking") || style.contains("vogue") { return Color(red: 0.70, green: 0.18, blue: 0.82) }
        if style.contains("house") { return Color(red: 0.18, green: 0.52, blue: 0.90) }
        if style.contains("breaking") { return Color(red: 0.20, green: 0.60, blue: 0.55) }
        if style.contains("locking") { return Color(red: 0.95, green: 0.60, blue: 0.20) }
        if style.contains("turfing") { return Color(red: 0.30, green: 0.45, blue: 0.85) }
        if style.contains("chinese") { return Color(red: 0.80, green: 0.20, blue: 0.25) }
        if style.contains("pro dance") { return Color(red: 0.50, green: 0.50, blue: 0.55) }
        if style.contains("choreography") { return Color(red: 0.45, green: 0.40, blue: 0.75) }
        return .indigo
    }
}

struct Studio: Codable, Identifiable {
    let name: String
    let scheduleUrls: [String]

    var id: String { name }
    var scheduleUrl: String? { scheduleUrls.first }

    enum CodingKeys: String, CodingKey {
        case name
        case scheduleUrls = "schedule_urls"
    }
}

struct StudioInfo: Codable, Hashable {
    let name: String
    let scheduleUrls: [String]?

    var scheduleUrl: String? { scheduleUrls?.first }

    enum CodingKeys: String, CodingKey {
        case name
        case scheduleUrls = "schedule_urls"
    }
}

struct LocationInfo: Codable, Hashable {
    let name: String?
    let address: String?
    let city: String?
}

extension String {
    var dateLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: self) else { return self }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let display = DateFormatter()
        display.dateFormat = "EEEE, MMM d"
        return display.string(from: d)
    }

    var levelDisplayName: String {
        switch self {
        case "beginner": return "Beginner"
        case "intermediate": return "Intermediate"
        case "advanced": return "Advanced"
        case "master": return "Master"
        case "begin/int": return "Beg / Int"
        case "int/adv": return "Int / Adv"
        case "all_levels": return "All Levels"
        default: return self.capitalized
        }
    }

    var levelColor: Color {
        switch self {
        case "beginner": return .green
        case "begin/int": return Color(red: 0.60, green: 0.80, blue: 0.20)
        case "intermediate": return .orange
        case "int/adv": return Color(red: 0.90, green: 0.40, blue: 0.15)
        case "advanced": return .red
        case "master": return Color(red: 0.55, green: 0.10, blue: 0.85)
        case "all_levels": return .blue
        default: return .gray
        }
    }
}

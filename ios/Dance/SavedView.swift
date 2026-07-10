import SwiftUI
import EventKit
import EventKitUI

// Shared log-entry UI used by ProfileView (your own saved/logged classes) and
// UserProfileView (someone else's, read-only). There's no dedicated "Saved" tab —
// saved/logged classes live in the Profile tab.

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kTertiary = Color(white: 0.38)

struct LogEntryRow: View {
    let entry: LogEntry
    var isShared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(kSecondary)
                Text("· \(entry.duration) min")
                    .font(.caption).foregroundStyle(kTertiary)
                Spacer()
                if entry.isCanceled {
                    Text("Canceled")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.red.opacity(0.25))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
                if isShared {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.62, green: 0.35, blue: 1.0))
                        .padding(.trailing, 2)
                        .help("You've both done this class")
                }
                if !entry.level.isEmpty && entry.level != "all_levels" {
                    Text(entry.level.levelDisplayName)
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(entry.level.levelColor.opacity(0.25))
                        .foregroundStyle(entry.level.levelColor)
                        .clipShape(Capsule())
                }
            }
            let displayTitle = entry.title.isEmpty
                ? (entry.danceStyle.isEmpty ? "Dance Class" : entry.danceStyle)
                : entry.title
            Text(displayTitle)
                .font(.subheadline).fontWeight(.semibold).foregroundStyle(.white)
            let meta = [entry.instructor, entry.studio].filter { !$0.isEmpty }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).font(.caption).foregroundStyle(kSecondary)
            }
            if !entry.notes.isEmpty {
                Text(entry.notes)
                    .font(.caption).foregroundStyle(kTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Log Entry Sheet (create or edit manual entries)

struct LogEntrySheet: View {
    let existing: LogEntry?
    @Environment(SavedStore.self) private var savedStore
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var duration: Int
    @State private var danceStyle: String
    @State private var level: String
    @State private var instructor: String
    @State private var studio: String
    @State private var notes: String

    private let levels = ["beginner", "begin/int", "intermediate", "int/adv", "advanced", "master", "all_levels"]
    @State private var showCalendar = false

    init(existing: LogEntry? = nil) {
        self.existing = existing
        // Default a new entry an hour out, not to the exact current instant — the
        // list only shows entries with date >= now, so a "right now" default would
        // already read as expired by the time someone finishes filling out the form.
        _date = State(initialValue: existing?.date ?? Date().addingTimeInterval(3600))
        _duration = State(initialValue: existing?.duration ?? 60)
        _danceStyle = State(initialValue: existing?.danceStyle ?? "")
        _level = State(initialValue: existing?.level ?? "all_levels")
        _instructor = State(initialValue: existing?.instructor ?? "")
        _studio = State(initialValue: existing?.studio ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section {
                        DatePicker("Date & Time", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        Stepper("Duration: \(duration) min", value: $duration, in: 15...240, step: 15)
                    }
                    Section("Class") {
                        TextField("Style (e.g. Jazz Funk, Hip Hop)", text: $danceStyle)
                        Picker("Level", selection: $level) {
                            ForEach(levels, id: \.self) { l in
                                Text(l.levelDisplayName).tag(l)
                            }
                        }
                    }
                    Section("Instructor & Studio") {
                        TextField("Instructor", text: $instructor)
                        TextField("Studio", text: $studio)
                    }
                    Section("Notes") {
                        TextEditor(text: $notes)
                            .frame(minHeight: 80)
                    }
                    if existing != nil {
                        Section {
                            Button {
                                showCalendar = true
                            } label: {
                                Label("Add to Calendar", systemImage: "calendar.badge.plus")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .sheet(isPresented: $showCalendar) {
                if let entry = existing {
                    LogCalendarSheet(entry: entry)
                }
            }
            .navigationTitle(existing == nil ? "Log a Class" : "Edit Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if var entry = existing {
                            entry.date = date
                            entry.duration = duration
                            entry.danceStyle = danceStyle
                            entry.level = level
                            entry.instructor = instructor
                            entry.studio = studio
                            entry.notes = notes
                            savedStore.updateLog(entry)
                        } else {
                            savedStore.addLog(LogEntry(
                                date: date, duration: duration, title: "",
                                danceStyle: danceStyle, level: level,
                                instructor: instructor, studio: studio, notes: notes
                            ))
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Log Entry Detail Sheet (read-only, for classes logged from hearted list)

struct LogEntryDetailSheet: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var showCalendar = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if entry.isCanceled {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("This class was canceled by the studio.")
                            }
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                        }
                        VStack(spacing: 0) {
                            DetailRow(icon: "calendar", label: "Date", value: entry.date.formatted(date: .long, time: .omitted))
                            Divider().overlay(Color(white: 0.18)).padding(.leading, 50)
                            DetailRow(icon: "clock", label: "Time", value: "\(entry.date.formatted(date: .omitted, time: .shortened)) · \(entry.duration) min")
                            if !entry.danceStyle.isEmpty {
                                Divider().overlay(Color(white: 0.18)).padding(.leading, 50)
                                DetailRow(icon: "music.note", label: "Style", value: entry.danceStyle)
                            }
                            if !entry.level.isEmpty && entry.level != "all_levels" {
                                Divider().overlay(Color(white: 0.18)).padding(.leading, 50)
                                DetailRow(icon: "chart.bar", label: "Level", value: entry.level.levelDisplayName)
                            }
                            if !entry.instructor.isEmpty {
                                Divider().overlay(Color(white: 0.18)).padding(.leading, 50)
                                DetailRow(icon: "person", label: "Instructor", value: entry.instructor)
                            }
                            if !entry.studio.isEmpty {
                                Divider().overlay(Color(white: 0.18)).padding(.leading, 50)
                                DetailRow(icon: "building.2", label: "Studio", value: entry.studio)
                            }
                        }
                        .background(Color(white: 0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(16)

                        if !entry.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Notes")
                                    .font(.headline).foregroundStyle(.white)
                                Text(entry.notes)
                                    .font(.body).foregroundStyle(Color(white: 0.6))
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }

                        Button {
                            showCalendar = true
                        } label: {
                            Label("Add to Calendar", systemImage: "calendar.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(white: 0.15))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .sheet(isPresented: $showCalendar) { LogCalendarSheet(entry: entry) }
            .navigationTitle(entry.title.isEmpty ? entry.danceStyle : entry.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct LogCalendarSheet: UIViewControllerRepresentable {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        let displayTitle = entry.title.isEmpty ? (entry.danceStyle.isEmpty ? "Dance Class" : entry.danceStyle) : entry.title
        event.title = displayTitle
        event.startDate = entry.date
        event.endDate = entry.date.addingTimeInterval(Double(entry.duration) * 60)
        var notes: [String] = []
        if !entry.instructor.isEmpty { notes.append("Instructor: \(entry.instructor)") }
        if !entry.studio.isEmpty { notes.append("Studio: \(entry.studio)") }
        if !entry.notes.isEmpty { notes.append(entry.notes) }
        event.notes = notes.joined(separator: "\n")
        let vc = EKEventEditViewController()
        vc.event = event
        vc.eventStore = store
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    class Coordinator: NSObject, EKEventEditViewDelegate {
        let parent: LogCalendarSheet
        init(_ parent: LogCalendarSheet) { self.parent = parent }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            parent.dismiss()
        }
    }
}

struct DetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(Color(white: 0.5))
                .padding(.leading, 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(Color(white: 0.45))
                Text(value).font(.subheadline).foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(.vertical, 13)
    }
}

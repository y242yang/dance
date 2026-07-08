import SwiftUI
import EventKit
import EventKitUI

private let kBg = Color.black
private let kSecondary = Color(white: 0.52)
private let kTertiary = Color(white: 0.38)

struct SavedView: View {
    @Environment(SavedStore.self) private var savedStore
    @State private var classes: [DanceClass] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showLogSheet = false
    @State private var selectedEntry: LogEntry?

    // "My Class Log" is for classes you're committed to attending, not a history —
    // once a logged class's date passes, it drops out of this list. The underlying
    // entry isn't deleted, just no longer shown here.
    private var upcomingLogEntries: [LogEntry] {
        savedStore.logEntries.filter { $0.date >= Date() }
    }

    var body: some View {
        ZStack {
            kBg.ignoresSafeArea()

            if isLoading && classes.isEmpty {
                ProgressView("Loading…")
                    .tint(Color(red: 0.62, green: 0.35, blue: 1.0))
                    .foregroundStyle(.white)
            } else if savedStore.savedIds.isEmpty && upcomingLogEntries.isEmpty {
                emptyState
            } else if let err = error, classes.isEmpty && upcomingLogEntries.isEmpty {
                DarkErrorView(message: err) { Task { await fetch() } }
            } else {
                contentView
            }
        }
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(kBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showLogSheet = true } label: {
                    Image(systemName: "square.and.pencil").foregroundStyle(.white)
                }
            }
        }
        .sheet(isPresented: $showLogSheet) { LogEntrySheet() }
        .sheet(item: $selectedEntry) { entry in
            if entry.isManual {
                LogEntrySheet(existing: entry)
            } else {
                LogEntryDetailSheet(entry: entry)
            }
        }
        .task(id: savedStore.savedIds) { await fetch() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart")
                .font(.system(size: 52))
                .foregroundStyle(Color(red: 0.62, green: 0.35, blue: 1.0))
            Text("No saved classes yet")
                .font(.title3).fontWeight(.semibold).foregroundStyle(.white)
            Text("Tap the heart on any class to save it here, or tap ✏️ to log a class you're confirmed to attend.")
                .foregroundStyle(kSecondary).multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var contentView: some View {
        List {
            // Saved upcoming classes
            if !savedStore.savedIds.isEmpty {
                if classes.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "heart.slash")
                            .font(.system(size: 36)).foregroundStyle(kTertiary)
                        Text("No upcoming saved classes")
                            .foregroundStyle(.white).font(.headline)
                        Text("Saved classes that have passed won't show here.")
                            .foregroundStyle(kSecondary).font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(kBg)
                    .listRowSeparator(.hidden)
                } else {
                    let grouped = Dictionary(grouping: classes, by: \.date)
                    let sections = grouped.sorted { $0.key < $1.key }
                        .map { (date: $0.key, label: $0.key.dateLabel, classes: $0.value.sorted { $0.startTime < $1.startTime }) }
                    ForEach(sections, id: \.date) { section in
                        Section(header: sectionHeader(section.label)) {
                            ForEach(section.classes) { cls in
                                NavigationLink(value: cls) {
                                    DarkClassRow(cls: cls, isSaved: true) {
                                        savedStore.toggle(cls.id)
                                    }
                                }
                                .listRowBackground(kBg)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        savedStore.toggle(cls.id)
                                    } label: {
                                        Label("Unheart", systemImage: "heart.slash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        savedStore.addLog(logEntry(from: cls))
                                        savedStore.toggle(cls.id)
                                    } label: {
                                        Label("Log", systemImage: "checkmark.circle")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                    }
                }
            }

            // Log section
            if !upcomingLogEntries.isEmpty {
                Section(header: sectionHeader("My Class Log")) {
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
        }
        .listStyle(.plain)
        .background(kBg)
        .scrollContentBackground(.hidden)
        .refreshable { await fetch() }
        .navigationDestination(for: DanceClass.self) { cls in
            ClassDetailView(cls: cls)
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(kSecondary)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kBg)
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

private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(kSecondary)
                Text("· \(entry.duration) min")
                    .font(.caption).foregroundStyle(kTertiary)
                Spacer()
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

private struct LogEntrySheet: View {
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
        _date = State(initialValue: existing?.date ?? Date())
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

private struct LogEntryDetailSheet: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var showCalendar = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
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

private struct LogCalendarSheet: UIViewControllerRepresentable {
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

private struct DetailRow: View {
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

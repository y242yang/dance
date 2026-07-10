import Foundation
import Observation
import Supabase

struct LogEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var duration: Int
    var title: String
    var danceStyle: String
    var level: String
    var instructor: String
    var studio: String
    var notes: String
    var sourceClassId: String?  // non-nil = logged from a hearted class
    var isCanceled: Bool = false  // source class was canceled after commit; source_class_id has been detached

    var isManual: Bool { sourceClassId == nil && !isCanceled }

    /// Two logged sessions count as the "same" for the shared-session badge:
    /// same source class, or (for manual entries, which have no class id to
    /// compare) same minute and same instructor first name.
    func isSameSession(as other: LogEntry) -> Bool {
        if let mine = sourceClassId, let theirs = other.sourceClassId {
            return mine == theirs
        }
        guard isManual, other.isManual else { return false }
        guard Calendar.current.isDate(date, equalTo: other.date, toGranularity: .minute) else { return false }
        let name = Self.normalizedFirstName(instructor)
        return !name.isEmpty && name == Self.normalizedFirstName(other.instructor)
    }

    private static func normalizedFirstName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map { $0.lowercased() } ?? ""
    }
}

/// Saving/logging classes requires an account. This is a thin live cache over
/// the `saved_classes`/`log_entries` tables in Supabase — there is no local
/// persistence, so there's exactly one source of truth and no drift to manage.
/// `savedIds`/`logEntries` are populated by loadFromCloud() when userId is set,
/// and cleared when signed out.
@Observable
final class SavedStore {
    private(set) var savedIds: Set<String> = []
    var logEntries: [LogEntry] = []
    private(set) var isLoading = false

    var userId: UUID? {
        didSet {
            guard oldValue != userId else { return }
            if let userId {
                Task { await loadFromCloud(userId: userId) }
            } else {
                savedIds = []
                logEntries = []
            }
        }
    }

    /// Log entries are commitments to attend an upcoming class, not a history —
    /// once the date passes, delete them (locally and in the cloud).
    func pruneExpiredLogs() {
        let expired = logEntries.filter { $0.date < Date() }
        guard !expired.isEmpty else { return }
        logEntries.removeAll { $0.date < Date() }
        for entry in expired { mirrorLogDelete(id: entry.id) }
    }

    /// Removes saved-class ids that no longer correspond to an upcoming class
    /// (called by SavedView/ProfileView after they fetch the current upcoming set).
    func pruneSaved(keeping upcomingIds: Set<String>) {
        guard let userId else { return }
        let stale = savedIds.subtracting(upcomingIds)
        guard !stale.isEmpty else { return }
        savedIds.subtract(stale)
        for idString in stale {
            guard let id = UUID(uuidString: idString) else { continue }
            mirrorSavedDelete(userId: userId, classId: id)
        }
    }

    func isSaved(_ id: UUID) -> Bool {
        savedIds.contains(id.uuidString)
    }

    func toggle(_ id: UUID) {
        guard let userId else { return }
        let s = id.uuidString
        let nowSaved = !savedIds.contains(s)
        if nowSaved { savedIds.insert(s) } else { savedIds.remove(s) }
        if nowSaved {
            Task {
                do {
                    try await supabase.from("saved_classes")
                        .insert(CloudSavedClass(userId: userId, classId: id))
                        .execute()
                } catch {
                    print("SavedStore.toggle insert failed: \(error)")
                }
            }
        } else {
            mirrorSavedDelete(userId: userId, classId: id)
        }
    }

    func addLog(_ entry: LogEntry) {
        guard let userId else { return }
        logEntries.insert(entry, at: 0)
        mirrorLogUpsert(userId: userId, entry)
    }

    func updateLog(_ entry: LogEntry) {
        guard let userId else { return }
        guard let idx = logEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        logEntries[idx] = entry
        mirrorLogUpsert(userId: userId, entry)
    }

    /// Saved and logged are independent: deleting a log entry never touches
    /// saved_classes, and unsaving a class never touches its log entry.
    func deleteLog(id: UUID) {
        guard userId != nil else { return }
        logEntries.removeAll { $0.id == id }
        mirrorLogDelete(id: id)
    }

    // MARK: - Cloud

    private func loadFromCloud(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let saved: [SavedClassIdRow] = try await supabase
                .from("saved_classes")
                .select("class_id")
                .eq("user_id", value: userId)
                .execute()
                .value
            let logs: [CloudLogEntry] = try await supabase
                .from("log_entries")
                .select("*")
                .eq("user_id", value: userId)
                .order("date", ascending: false)
                .execute()
                .value
            savedIds = Set(saved.map { $0.classId.uuidString })
            logEntries = logs.map(\.asLogEntry)
            pruneExpiredLogs()
        } catch {
            print("SavedStore.loadFromCloud failed: \(error)")
        }
    }

    private func mirrorSavedDelete(userId: UUID, classId: UUID) {
        Task {
            do {
                try await supabase.from("saved_classes")
                    .delete()
                    .eq("user_id", value: userId)
                    .eq("class_id", value: classId)
                    .execute()
            } catch {
                print("SavedStore.mirrorSavedDelete failed: \(error)")
            }
        }
    }

    private func mirrorLogUpsert(userId: UUID, _ entry: LogEntry) {
        Task {
            do {
                try await supabase.from("log_entries")
                    .upsert(CloudLogEntry(userId: userId, entry: entry))
                    .execute()
            } catch {
                print("SavedStore.mirrorLogUpsert failed: \(error)")
            }
        }
    }

    private func mirrorLogDelete(id: UUID) {
        Task {
            do {
                try await supabase.from("log_entries").delete().eq("id", value: id).execute()
            } catch {
                print("SavedStore.mirrorLogDelete failed: \(error)")
            }
        }
    }
}

private struct SavedClassIdRow: Decodable {
    let classId: UUID
    enum CodingKeys: String, CodingKey { case classId = "class_id" }
}

private struct CloudSavedClass: Codable {
    let userId: UUID
    let classId: UUID
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case classId = "class_id"
    }
}

/// Mirrors the `log_entries` table shape. Used both to write the local
/// `LogEntry` up to Supabase, and (via `asLogEntry`) to read it back down
/// for display.
struct CloudLogEntry: Codable {
    let id: UUID
    let userId: UUID
    let date: Date
    let durationMinutes: Int
    let title: String
    let danceStyle: String
    let level: String
    let instructor: String
    let studio: String
    let notes: String
    let sourceClassId: UUID?
    let isCanceled: Bool

    enum CodingKeys: String, CodingKey {
        case id, date, title, level, instructor, studio, notes
        case userId = "user_id"
        case durationMinutes = "duration_minutes"
        case danceStyle = "dance_style"
        case sourceClassId = "source_class_id"
        case isCanceled = "is_canceled"
    }

    init(userId: UUID, entry: LogEntry) {
        id = entry.id
        self.userId = userId
        date = entry.date
        durationMinutes = entry.duration
        title = entry.title
        danceStyle = entry.danceStyle
        level = entry.level
        instructor = entry.instructor
        studio = entry.studio
        notes = entry.notes
        sourceClassId = entry.sourceClassId.flatMap(UUID.init)
        isCanceled = entry.isCanceled
    }

    var asLogEntry: LogEntry {
        LogEntry(
            id: id, date: date, duration: durationMinutes, title: title,
            danceStyle: danceStyle, level: level, instructor: instructor,
            studio: studio, notes: notes, sourceClassId: sourceClassId?.uuidString,
            isCanceled: isCanceled
        )
    }
}

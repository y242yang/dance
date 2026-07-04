import Foundation
import Observation

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

    var isManual: Bool { sourceClassId == nil }
}

@Observable
final class SavedStore {
    private(set) var savedIds: Set<String> = []
    var logEntries: [LogEntry] = []

    private let savedKey = "savedClassIds"
    private let logKey = "danceLogEntries"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: savedKey) ?? []
        savedIds = Set(stored)
        if let data = UserDefaults.standard.data(forKey: logKey),
           let entries = try? JSONDecoder().decode([LogEntry].self, from: data) {
            logEntries = entries
        }
    }

    func isSaved(_ id: UUID) -> Bool {
        savedIds.contains(id.uuidString)
    }

    func toggle(_ id: UUID) {
        let s = id.uuidString
        if savedIds.contains(s) { savedIds.remove(s) } else { savedIds.insert(s) }
        UserDefaults.standard.set(Array(savedIds), forKey: savedKey)
    }

    func addLog(_ entry: LogEntry) {
        logEntries.insert(entry, at: 0)
        persistLog()
    }

    func updateLog(_ entry: LogEntry) {
        if let idx = logEntries.firstIndex(where: { $0.id == entry.id }) {
            logEntries[idx] = entry
            persistLog()
        }
    }

    func deleteLog(id: UUID) {
        if let entry = logEntries.first(where: { $0.id == id }),
           let sourceId = entry.sourceClassId {
            savedIds.insert(sourceId)
            UserDefaults.standard.set(Array(savedIds), forKey: savedKey)
        }
        logEntries.removeAll { $0.id == id }
        persistLog()
    }

    private func persistLog() {
        if let data = try? JSONEncoder().encode(logEntries) {
            UserDefaults.standard.set(data, forKey: logKey)
        }
    }
}

import Foundation
import Observation

@Observable
final class SavedStore {
    private(set) var savedIds: Set<String> = []
    private let key = "savedClassIds"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        savedIds = Set(stored)
    }

    func isSaved(_ id: UUID) -> Bool {
        savedIds.contains(id.uuidString)
    }

    func toggle(_ id: UUID) {
        let s = id.uuidString
        if savedIds.contains(s) {
            savedIds.remove(s)
        } else {
            savedIds.insert(s)
        }
        UserDefaults.standard.set(Array(savedIds), forKey: key)
    }
}

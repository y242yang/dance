import XCTest
@testable import Dance

final class LogEntryTests: XCTestCase {

    private func makeEntry(
        sourceClassId: String? = nil,
        isCanceled: Bool = false,
        date: Date = Date(),
        instructor: String = "Yanis Marshall"
    ) -> LogEntry {
        LogEntry(
            date: date, duration: 60, title: "Heels", danceStyle: "Heels",
            level: "advanced", instructor: instructor, studio: "Moving Arts",
            notes: "", sourceClassId: sourceClassId, isCanceled: isCanceled
        )
    }

    // MARK: - isManual

    func testManualEntryHasNoSourceClassAndIsNotCanceled() {
        let entry = makeEntry(sourceClassId: nil, isCanceled: false)
        XCTAssertTrue(entry.isManual)
    }

    func testClassSourcedEntryIsNotManual() {
        let entry = makeEntry(sourceClassId: UUID().uuidString, isCanceled: false)
        XCTAssertFalse(entry.isManual)
    }

    func testCanceledEntryIsNotTreatedAsManualEvenThoughSourceClassIdIsNil() {
        // This is exactly the bug the flag exists to fix: once a class is
        // canceled, the FK detaches (source_class_id -> NULL), but the entry
        // must still render read-only, not flip into the editable manual sheet.
        let entry = makeEntry(sourceClassId: nil, isCanceled: true)
        XCTAssertFalse(entry.isManual)
    }

    // MARK: - isSameSession

    func testSameSourceClassIdIsSameSession() {
        let classId = UUID().uuidString
        let a = makeEntry(sourceClassId: classId)
        let b = makeEntry(sourceClassId: classId)
        XCTAssertTrue(a.isSameSession(as: b))
    }

    func testDifferentSourceClassIdIsNotSameSession() {
        let a = makeEntry(sourceClassId: UUID().uuidString)
        let b = makeEntry(sourceClassId: UUID().uuidString)
        XCTAssertFalse(a.isSameSession(as: b))
    }

    func testManualEntriesSameMinuteAndInstructorFirstNameAreSameSession() {
        let date = Date()
        let a = makeEntry(date: date, instructor: "Yanis Marshall")
        let b = makeEntry(date: date, instructor: "yanis") // case-insensitive, first-name only
        XCTAssertTrue(a.isSameSession(as: b))
    }

    func testManualEntriesDifferentMinuteAreNotSameSession() {
        let a = makeEntry(date: Date(), instructor: "Yanis")
        let b = makeEntry(date: Date().addingTimeInterval(120), instructor: "Yanis")
        XCTAssertFalse(a.isSameSession(as: b))
    }

    func testManualEntriesDifferentInstructorAreNotSameSession() {
        let date = Date()
        let a = makeEntry(date: date, instructor: "Yanis")
        let b = makeEntry(date: date, instructor: "Kaycee")
        XCTAssertFalse(a.isSameSession(as: b))
    }

    func testManualVsClassSourcedAreNeverSameSession() {
        let date = Date()
        let manual = makeEntry(sourceClassId: nil, date: date, instructor: "Yanis")
        let classSourced = makeEntry(sourceClassId: UUID().uuidString, date: date, instructor: "Yanis")
        XCTAssertFalse(manual.isSameSession(as: classSourced))
    }

    func testEmptyInstructorNameNeverMatchesForManualEntries() {
        let date = Date()
        let a = makeEntry(date: date, instructor: "")
        let b = makeEntry(date: date, instructor: "")
        XCTAssertFalse(a.isSameSession(as: b))
    }
}

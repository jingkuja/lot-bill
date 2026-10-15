import XCTest
import SwiftData
@testable import LotBill

final class PersistenceSmokeTests: XCTestCase {
    @MainActor
    func testSavedRecordSurvivesReopeningStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lot-bill-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([DevelopmentRecord.self])
        let configuration = ModelConfiguration(
            "PersistenceSmokeTest", schema: schema,
            url: directory.appendingPathComponent("Test.store"), cloudKitDatabase: .none
        )
        let text = "Synthetic persistence check"

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(DevelopmentRecord(text: text))
            try context.save()
        }

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let saved = try ModelContext(reopened).fetch(FetchDescriptor<DevelopmentRecord>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.text, text)
    }
}


@MainActor final class M7ScaleTests: XCTestCase {
    func testTenThousandTransactionsOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try LedgerRepository(container: LedgerStore.container(inMemory: true))
        try source.commit {
            for index in 0..<10_000 {
                let entry = LedgerEntry(id: "scale-\(index)", kind: .expense, amountCents: 101,
                    day: String(format: "2026-09-%02d", index % 30 + 1))
                entry.categoryID = "expense.daily.2"; entry.note = "Synthetic scale \(index)"
                source.context.insert(entry)
            }
        }
        var timings: [String: Double] = [:]
        func timed<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
            let start = Date(); defer { timings[name] = Date().timeIntervalSince(start) }
            return try operation()
        }
        let bytes = try timed("backup_encode") { try source.backup().encoded() }
        let incoming = try timed("backup_decode") { try LedgerBackup.decode(bytes) }
        let url = folder.appendingPathComponent("Scale.store")
        let target = try LedgerRepository(container: LedgerStore.container(url: url))
        try timed("bulk_restore_disk") { try target.restore(incoming, expectedRevision: target.revision, directory: folder.appendingPathComponent("recovery")) }
        XCTAssertEqual(target.entries.count, 10_000)
        let month = try LedgerPeriod(start: "2026-09-01", end: "2026-09-30")
        let totals = try timed("month_statistics") { try LedgerStatistics.calculate(period: month, entries: target.entries) }
        XCTAssertEqual(totals.netExpense, 1_010_000); XCTAssertEqual(totals.entryCount, 10_000)
        let found = timed("query_note") { target.entries.filter { month.contains($0.day) && $0.note.localizedCaseInsensitiveContains("scale 9999") } }
        XCTAssertEqual(found.map(\.id), ["scale-9999"])
        let csv = try timed("csv_export") { try target.csv(kind: .entries, period: month, includeInactive: false, bom: true) }
        XCTAssertEqual(csv.count, 10_000)
        let parsed = try TabularFile.parse(data: Data("大类,分类,金额\n日常支出,餐饮,1200".utf8), name: "synthetic-history.csv")
        var mapping = ImportMapping(); mapping.lastRow = 2; mapping.year = 2025
        try timed("history_import_with_10000_entries") { try target.importFile(target.preview(file: parsed, mapping: mapping, purpose: .history)) }
        let reopened = try timed("reopen_disk") { try LedgerRepository(container: LedgerStore.container(url: url)) }
        XCTAssertEqual(reopened.entries.count, 10_000); XCTAssertEqual(reopened.histories.count, 1)
        XCTAssertEqual(try LedgerStatistics.calculate(period: month, entries: reopened.entries).netExpense, 1_010_000)
        let report = try JSONSerialization.data(withJSONObject: timings, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
        attachment.name = "M7-10000-timings-seconds"; attachment.lifetime = .keepAlways; add(attachment)
        print("M7_SCALE_SECONDS " + String(decoding: report, as: UTF8.self))
        XCTAssertLessThan(timings["month_statistics"]!, 2)
        XCTAssertLessThan(timings["query_note"]!, 2)
        XCTAssertLessThan(timings["bulk_restore_disk"]!, 30)
    }
}

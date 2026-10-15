import XCTest
import SwiftData
import ZIPFoundation
@testable import LotBill

final class TabularFileTests: XCTestCase {
    func testCSVQuotesBOMNewlinesAndBoundaries() throws {
        let sheet = try TabularFile.csv(Data("\u{FEFF}分类,备注,金额\r\n餐饮,\"quoted \"\"word\"\"\nnext,part\",\"1,234.56\"\r\n".utf8))
        XCTAssertEqual(sheet.rows.count, 2)
        XCTAssertEqual(sheet.cell(row: 2, column: 1).text, "quoted \"word\"\nnext,part")
        XCTAssertEqual(sheet.cell(row: 2, column: 2).text, "1,234.56")
        for invalid in ["a,\"unfinished", "\"a\"x,b", "ab\"c,d"] { XCTAssertThrowsError(try TabularFile.csv(Data(invalid.utf8))) }
        XCTAssertThrowsError(try TabularFile.csv(Data([0xFF])))
        XCTAssertThrowsError(try TabularFile.csv(Data(String(repeating: "x\n", count: 10_001).utf8)))
        XCTAssertThrowsError(try TabularFile.parse(data: Data(repeating: 0, count: TabularFile.maximumBytes + 1), name: "large.csv"))
        XCTAssertThrowsError(try TabularFile.parse(data: Data("notzip".utf8), name: "bad.xlsx"))
        XCTAssertThrowsError(try TabularFile.csv(Data((String(repeating: "x,", count: 256) + "x").utf8)))
    }
    func testReadFileAndFlatColumnMapping() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("分类,金额\n餐饮,12.34".utf8).write(to: url)
        let file = try TabularFile.read(url: url)
        XCTAssertEqual(file.sheets[0].cell(row: 2, column: 1).text, "12.34")
    }
    func testExplicitAmountFormats() throws {
        XCTAssertNil(try AmountFormat.decimalPoint.parse(" "))
        XCTAssertEqual(try AmountFormat.decimalPoint.parse("0"), 0)
        XCTAssertEqual(try AmountFormat.decimalPoint.parse("￥ 1,234.50"), 123450)
        XCTAssertEqual(try AmountFormat.decimalComma.parse("1.234,50"), 123450)
        XCTAssertEqual(try AmountFormat.decimalPoint.parse("-0.50", signed: true), -50)
        for invalid in ["1,23", "1.234", "1e4", "NaN", "-2", "10000000001", "=1+2"] { XCTAssertThrowsError(try AmountFormat.decimalPoint.parse(invalid), invalid) }
    }
    // Synthetic OOXML fixtures exercise the actual pinned dependencies, not mocked cells.
    static func workbook(sheet: String, shared: String? = nil, extra: [String: Data] = [:]) throws -> Data {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var files: [String: Data] = [
            "_rels/.rels": Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>".utf8),
            "xl/workbook.xml": Data("<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rel)\"><sheets><sheet name=\"2026\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8),
            "xl/_rels/workbook.xml.rels": Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8),
            "xl/worksheets/sheet1.xml": Data("<worksheet xmlns=\"\(ns)\">\(sheet)</worksheet>".utf8)
        ]
        if let shared { files["xl/sharedStrings.xml"] = Data("<sst xmlns=\"\(ns)\">\(shared)</sst>".utf8) }
        files.merge(extra) { _, new in new }
        let archive = try Archive(accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
                data.subdata(in: Int(position)..<min(Int(position) + count, data.count))
            }
        }
        return try XCTUnwrap(archive.data)
    }
    func testXLSXSharedStringsMergesCachedMissingFormulaAndOutsideColumn() throws {
        let data = try Self.workbook(sheet: """
        <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>餐饮</t></is></c><c r="C1"><f>100+20</f><v>120</v></c><c r="U1"><f>999</f><v>999</v></c></row>
        <row r="2"><c r="B2" t="inlineStr"><is><t>超市</t></is></c><c r="C2"><v>0</v></c></row>
        <row r="3"><c r="B3" t="inlineStr"><is><t>理发</t></is></c><c r="C3"><f>SUM(C1:C2)</f></c></row></sheetData><mergeCells><mergeCell ref="A1:A2"/></mergeCells>
        """, shared: "<si><t>日常支出</t></si>")
        let file = try TabularFile.parse(data: data, name: "synthetic.xlsx")
        let sheet = try XCTUnwrap(file.sheets.first)
        XCTAssertEqual(sheet.name, "2026")
        XCTAssertEqual(sheet.cell(row: 2, column: 0, fillMerged: true).text, "日常支出")
        XCTAssertEqual(sheet.cell(row: 3, column: 0, fillMerged: true).text, "")
        XCTAssertEqual(sheet.cell(row: 1, column: 2).text, "120")
        XCTAssertTrue(sheet.cell(row: 1, column: 2).formula)
        XCTAssertNotNil(sheet.cell(row: 3, column: 2).error)
    }
    func testXLSXInlineWithoutSharedStringsAndUnsafeArchives() throws {
        let valid = try Self.workbook(sheet: "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>餐饮</t></is></c></row></sheetData>")
        XCTAssertEqual(try TabularFile.parse(data: valid, name: "inline.xlsx").sheets[0].cell(row: 1, column: 0).text, "餐饮")
        let duplicates = try Self.workbook(sheet: "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"A1\"><v>2</v></c></row></sheetData>")
        XCTAssertThrowsError(try TabularFile.parse(data: duplicates, name: "duplicate-cell.xlsx"))
        let traversal = try Self.workbook(sheet: "<sheetData/>", extra: ["../escape.xml": Data("x".utf8)])
        XCTAssertThrowsError(try TabularFile.parse(data: traversal, name: "unsafe.xlsx"))
        let dtd = try Self.workbook(sheet: "<sheetData/>", extra: ["extra.xml": Data("<!DOCTYPE test><test/>".utf8)])
        XCTAssertThrowsError(try TabularFile.parse(data: dtd, name: "dtd.xlsx"))
        let bomb = try Self.workbook(sheet: "<sheetData/>", extra: ["large.xml": Data(repeating: 65, count: 17 * 1024 * 1024)])
        XCTAssertThrowsError(try TabularFile.parse(data: bomb, name: "bomb.xlsx"))
    }
}

@MainActor final class ImportReconciliationTests: XCTestCase {
    private let dining = "expense.daily.2", daily = "expense.daily", clothing = "expense.clothing"
    private func repo() throws -> LedgerRepository { try LedgerRepository(container: LedgerStore.container(inMemory: true)) }
    /// History defaults to the whole of 2025; `month` selects a reconciliation month.
    private func preview(_ r: LedgerRepository, csv: String = "大类,分类,金额\n日常支出,餐饮,1200\n日常支出,超市,0\n日常支出,理发,\n总计,,1200", purpose: ImportPurpose = .history, month: String? = nil) throws -> ImportPreview {
        let file = try TabularFile.parse(data: Data(csv.utf8), name: "test.csv")
        var mapping = ImportMapping(); mapping.lastRow = file.sheets[0].rows.count; mapping.year = 2025
        if let month {
            let p = LedgerPeriod.month(containing: try LedgerDay(month + "-01").date())
            mapping.startDay = p.start.rawValue; mapping.endDay = p.end.rawValue; mapping.precision = .month
        }
        return try r.preview(file: file, mapping: mapping, purpose: purpose)
    }
    private func expense(_ r: LedgerRepository, amount: String = "1200", day: String = "2026-09-15") throws {
        try r.save(EntryDraft(amount: amount, day: day, categoryID: dining))
    }
    private func totals(_ r: LedgerRepository, month: String = "2026-09") throws -> LedgerTotals {
        try LedgerStatistics.calculate(period: .month(containing: LedgerDay(month + "-01").date()), entries: r.entries, histories: r.histories, adjustments: r.adjustments)
    }
    func testHistoryPreviewZeroBlankTotalDedupUndoAndUnsplitPeriod() throws {
        let r = try repo(), p = try preview(r)
        XCTAssertTrue(p.canCommit); XCTAssertEqual(p.total, 120000)
        XCTAssertEqual(p.summaries.first { $0.categoryID == dining }?.amountCents, 120000)
        XCTAssertNil(p.summaries.first { $0.categoryID == "expense.daily.0" }?.amountCents)
        try r.importFile(p)
        XCTAssertEqual(r.histories.count, 2)
        let history = try XCTUnwrap(r.histories.first { $0.categoryID == dining })
        XCTAssertEqual([history.categoryID, history.startDay, history.endDay, history.precision], [dining, "2025-01-01", "2025-12-31", "year"])
        XCTAssertTrue(try totals(r, month: "2025-02").unsplitPeriods.count == 1)
        XCTAssertEqual(try totals(r, month: "2025-02").consumption, 0)
        XCTAssertFalse(try preview(r).canCommit)
        let reexport = try preview(r, csv: "大类,分类,金额\n日常支出,餐饮,1200.00")
        XCTAssertFalse(reexport.canCommit)
        XCTAssertThrowsError(try r.importFile(p))
        try expense(r)
        XCTAssertTrue(r.historyCoverage.contains("空档"))
        let batch = try XCTUnwrap(r.batches.first)
        XCTAssertTrue(try r.undoImpact(batch).contains("2 项"))
        try r.undoBatch(batch)
        XCTAssertFalse(r.histories.contains(where: \.isActive)); XCTAssertEqual(r.entries.count, 1)
        XCTAssertTrue(try preview(r).canCommit)
    }
    func testHeaderlessMergedWorkbookSelectsChildrenYearAndCreatesMissingCategories() throws {
        let data = try TabularFileTests.workbook(sheet: """
        <sheetData><row r="1"><c r="C1" t="inlineStr"><is><t>1-8月</t></is></c></row>
        <row r="2"><c r="A2" t="inlineStr"><is><t> 日常支出 </t></is></c><c r="B2" t="inlineStr"><is><t> 餐饮 </t></is></c><c r="C2"><v>12.34</v></c><c r="U2"><f>999</f><v>999</v></c></row>
        <row r="3"><c r="B3" t="inlineStr"><is><t>新子类</t></is></c><c r="C3"><v>2</v></c></row>
        <row r="4"><c r="A4" t="inlineStr"><is><t>总计</t></is></c><c r="C4"><f>SUM(C2:C3)</f><v>14.34</v></c></row></sheetData>
        <mergeCells><mergeCell ref="A2:A3"/></mergeCells>
        """)
        let r = try repo(), file = try TabularFile.parse(data: data, name: "headerless.xlsx")
        var mapping = ImportMapping(); mapping.year = 2025; mapping.useHistorySheet(file.sheets[0])
        XCTAssertEqual(mapping.year, 2026); XCTAssertEqual(mapping.categoryColumn, 1); XCTAssertEqual(mapping.amountColumn, 2)
        let p = try r.preview(file: file, mapping: mapping, purpose: .history)
        XCTAssertTrue(p.canCommit); XCTAssertEqual(p.total, 1434); XCTAssertEqual(p.newCategories.count, 1)
        XCTAssertFalse(r.categories.contains { $0.name == "新子类" })
        try r.importFile(p)
        XCTAssertEqual(r.histories.count, 2)
        XCTAssertTrue(r.histories.allSatisfy { $0.endDay == "2026-08-31" && $0.categoryID != daily })
        XCTAssertEqual(r.categories.filter { $0.name == "新子类" }.count, 1)
        XCTAssertNoThrow(try r.backup().encoded())
        try r.undoBatch(XCTUnwrap(r.batches.first))
        try r.importFile(r.preview(file: file, mapping: mapping, purpose: .history))
        XCTAssertEqual(r.categories.filter { $0.name == "新子类" }.count, 1)
    }
    func testRenamedImportedCategoryIsNotOverwrittenByLaterImport() throws {
        let r = try repo()
        func importYear(_ year: Int, amount: String) throws {
            let file = try TabularFile.parse(data: Data("大类,第二分类,金额\n日常支出,新子类,\(amount)".utf8), name: "new.csv")
            var mapping = ImportMapping(); mapping.useHistorySheet(file.sheets[0]); mapping.year = year
            try r.importFile(r.preview(file: file, mapping: mapping, purpose: .history))
        }
        try importYear(2024, amount: "10")
        let original = try XCTUnwrap(r.categories.first { $0.name == "新子类" })
        try r.saveCategory(id: original.id, name: "重命名", parentID: daily, kind: .expense)
        try importYear(2025, amount: "20")
        XCTAssertEqual(original.name, "重命名")
        XCTAssertNotEqual(r.categories.first { $0.name == "新子类" }?.id, original.id)
        XCTAssertEqual(Set(r.histories.map(\.categoryID)).count, 2)
        XCTAssertNoThrow(try r.backup().encoded())
    }
    func testHistoryEditPreservesSourceInvalidatesReviewAndRoundTrips() throws {
        let r = try repo(); try r.importFile(preview(r))
        let h = try XCTUnwrap(r.histories.first { $0.categoryID == dining }), batch = try XCTUnwrap(r.batches.first)
        let original = try XCTUnwrap(r.importReceipt(batch)).history
        try r.saveStatement(month: "2025-02", values: [dining: 500])
        let statement = try XCTUnwrap(r.statements.first)
        try r.reviewStatement(statement, unresolvedReason: "年度未拆分")
        let revision = r.revision
        try r.editHistory(id: h.id, amount: "900", categoryID: dining, startDay: h.startDay, endDay: h.endDay, expectedRevision: revision)
        XCTAssertEqual(h.amountCents, 90000); XCTAssertFalse(statement.isReviewed)
        XCTAssertEqual(r.importReceipt(batch)?.history, original)
        XCTAssertThrowsError(try r.undoBatch(batch))
        XCTAssertThrowsError(try r.editHistory(id: h.id, amount: "1", categoryID: dining, startDay: h.startDay, endDay: h.endDay, expectedRevision: revision))
        let target = try repo(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try target.restore(LedgerBackup.decode(r.backup().encoded()), expectedRevision: target.revision, directory: folder)
        XCTAssertEqual(target.histories.first { $0.id == h.id }?.amountCents, 90000)
        XCTAssertTrue(target.audits.contains { $0.kind == "historyEdit" })
        let annual = try LedgerStatistics.calculate(period: LedgerPeriod(start: "2025-01-01", end: "2025-12-31"), entries: target.entries, histories: target.histories, parents: target.categoryParents)
        XCTAssertEqual(annual.netExpense, 90000); XCTAssertEqual(annual.byFirstCategory[daily], 90000)
    }
    func testHistoryEditRejectsOverlapAndSupportsPeriodCategoryAndZero() throws {
        let r = try repo(); try r.importFile(preview(r))
        let h = try XCTUnwrap(r.histories.first { $0.categoryID == dining })
        try expense(r, day: "2026-09-15")
        XCTAssertThrowsError(try r.editHistory(id: h.id, amount: "1", categoryID: daily, startDay: h.startDay, endDay: h.endDay, expectedRevision: r.revision))
        XCTAssertThrowsError(try r.editHistory(id: h.id, amount: "1", categoryID: dining, startDay: "2026-01-01", endDay: "2026-12-31", expectedRevision: r.revision))
        XCTAssertThrowsError(try r.editHistory(id: h.id, amount: "-1", categoryID: dining, startDay: h.startDay, endDay: h.endDay, expectedRevision: r.revision))
        try r.editHistory(id: h.id, amount: "0", categoryID: "expense.clothing.0", startDay: "2024-02-01", endDay: "2024-02-29", expectedRevision: r.revision)
        XCTAssertEqual(h.precision, "month"); XCTAssertEqual(h.amountCents, 0); XCTAssertEqual(h.categoryID, "expense.clothing.0")
        XCTAssertNoThrow(try r.backup().encoded())
    }
    func testBlankTemplateAndInvalidTotalsCannotCommit() throws {
        let r = try repo()
        XCTAssertFalse(try preview(r, csv: "大类,分类,金额\n日常支出,餐饮,\n日常支出,超市,").canCommit)
        XCTAssertFalse(try preview(r, csv: "大类,分类,金额\n日常支出,餐饮,2\n总计,,3").canCommit)
        XCTAssertFalse(try preview(r, csv: "大类,分类,金额\n日常支出,,2\n日常支出,,2").canCommit)
        XCTAssertFalse(try preview(r, csv: "大类,分类,金额\n未知大类,餐饮,2").canCommit)
    }
    func testChildRowsPreservedAndParentTotalsValidated() throws {
        let r = try repo()
        let summed = try preview(r, csv: "大类,分类,金额\n日常支出,餐饮,2\n日常支出,餐饮,3\n服饰,鞋帽,4")
        XCTAssertTrue(summed.canCommit); XCTAssertEqual(summed.total, 900)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: summed.summaries.map { ($0.categoryID, $0.amountCents) }), [dining: 500, "expense.clothing.1": 400])
        let explicit = try preview(r, csv: "大类,分类,金额\n日常支出,,1000\n日常支出,餐饮,300\n日常支出,超市,200\n总计,,1000")
        XCTAssertFalse(explicit.canCommit)
        let matching = try preview(r, csv: "大类,分类,金额\n日常支出,,500\n日常支出,餐饮,300\n日常支出,超市,200\n总计,,500")
        XCTAssertTrue(matching.canCommit); XCTAssertEqual(matching.total, 50000)
        XCTAssertEqual(Set(matching.summaries.map(\.categoryID)), Set([dining, "expense.daily.3"]))
        let flat = try TabularFile.parse(data: Data("大类,金额\n日常支出,80\n服饰,20".utf8), name: "flat-first-level.csv")
        var m = ImportMapping(); m.lastRow = 3; m.year = 2025; m.categoryColumn = -1; m.amountColumn = 1
        let p = try r.preview(file: flat, mapping: m, purpose: .history)
        XCTAssertTrue(p.canCommit); XCTAssertEqual(p.total, 10000)
    }
    func test2026AnnualSummaryEndsInAugustAndSeptemberContinuesNormally() throws {
        let r = try repo()
        let file = try TabularFile.parse(data: Data("大类,金额\n日常支出,800\n服饰,0\n娱乐,\n总计,800".utf8), name: "2026-annual.csv")
        var m = ImportMapping(); m.lastRow = 5; m.year = 2026; m.categoryColumn = -1; m.amountColumn = 1
        // Existing September entries must not prevent the annual history import.
        try expense(r, amount: "100", day: "2026-09-01")
        let p = try r.preview(file: file, mapping: m, purpose: .history)
        XCTAssertTrue(p.canCommit); XCTAssertEqual(p.total, 80000)
        XCTAssertTrue(p.summaries.allSatisfy { $0.startDay == "2026-01-01" && $0.endDay == "2026-08-31" && $0.precision == .range })
        XCTAssertTrue(p.summaries.allSatisfy { $0.period.contains("截至 8 月 31 日") })
        try r.importFile(p)
        XCTAssertEqual(r.histories.count, 2)
        XCTAssertEqual(Set(r.histories.map(\.categoryID)), Set([daily, clothing]))
        XCTAssertEqual(r.histories.first { $0.categoryID == clothing }?.amountCents, 0)
        let august = try totals(r, month: "2026-08")
        XCTAssertEqual(august.netExpense, 0)
        XCTAssertEqual(august.unsplitPeriods, ["2026-01-01 至 2026-08-31"])
        XCTAssertThrowsError(try expense(r, day: "2026-08-31"))
        try expense(r, amount: "50", day: "2026-09-30")
        XCTAssertEqual(try totals(r).netExpense, 15000)
        XCTAssertTrue(try totals(r).unsplitPeriods.isEmpty)
        let annual = try LedgerStatistics.calculate(period: LedgerPeriod(start: "2026-01-01", end: "2026-12-31"), entries: r.entries, histories: r.histories, parents: r.categoryParents)
        XCTAssertEqual(annual.netExpense, 95000)
        XCTAssertTrue(annual.unsplitPeriods.isEmpty)
        XCTAssertTrue(r.historyCoverage.contains("2026-08-31"))
        XCTAssertFalse(r.historyCoverage.contains("空档"))
        let batch = try XCTUnwrap(r.batches.first)
        XCTAssertTrue(try XCTUnwrap(r.importReceipt(batch)).history.allSatisfy { $0.end == "2026-08-31" && $0.precision == "range" })
        XCTAssertFalse(try r.preview(file: file, mapping: m, purpose: .history).canCommit)
        try r.undoBatch(batch)
        XCTAssertFalse(r.histories.contains(where: \.isActive))
        XCTAssertEqual(r.entries.count, 2)
    }
    func testHistoryRejectsMonthlyAndArbitraryRangeImports() throws {
        let r = try repo()
        let file = try TabularFile.parse(data: Data("大类,分类,1月,2月\n日常支出,餐饮,100,200".utf8), name: "monthly.csv")
        var m = ImportMapping(); m.lastRow = 2; m.year = 2026
        for precision in [PeriodPrecision.month, .range] {
            m.precision = precision
            XCTAssertThrowsError(try r.preview(file: file, mapping: m, purpose: .history))
        }
        m.precision = .year
        m.year = 1899
        XCTAssertThrowsError(try r.preview(file: file, mapping: m, purpose: .history))
        m.year = 2101
        XCTAssertThrowsError(try r.preview(file: file, mapping: m, purpose: .history))
    }
    func testFlatMappingOverrideAndFormulaCacheFailure() throws {
        let r = try repo()
        let file = try TabularFile.parse(data: Data("自定义,金额\n食物,12.34".utf8), name: "flat.csv")
        var m = ImportMapping(); m.lastRow = 2; m.parentColumn = 0; m.categoryColumn = -1; m.amountColumn = 1
        XCTAssertFalse(try r.preview(file: file, mapping: m, purpose: .history).canCommit)
        m.categoryOverrides[2] = dining
        XCTAssertTrue(try r.preview(file: file, mapping: m, purpose: .history).canCommit)
        m.categoryOverrides[2] = daily
        let p = try r.preview(file: file, mapping: m, purpose: .history)
        XCTAssertTrue(p.canCommit); XCTAssertEqual(p.total, 1234)
        let data = try TabularFileTests.workbook(sheet: "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>餐饮</t></is></c><c r=\"B1\"><f>1+2</f></c></row></sheetData>")
        let xlsx = try TabularFile.parse(data: data, name: "nocache.xlsx")
        m.firstRow = 1; m.lastRow = 1; m.categoryOverrides = [1: daily]
        XCTAssertFalse(try r.preview(file: xlsx, mapping: m, purpose: .history).canCommit)
    }
    func testNegativeAdjustmentAndReviewedBatchUndoProtection() throws {
        let r = try repo(); try expense(r)
        try r.importFile(preview(r, csv: "大类,分类,金额\n日常支出,餐饮,1000", purpose: .reconciliation, month: "2026-09"))
        let s = try XCTUnwrap(r.statements.first), item = try XCTUnwrap(r.statementItems.first { $0.amountCents != nil })
        try r.reviseAdjustment(itemID: item.id, expectedCents: -20000, reason: "correction")
        XCTAssertEqual(try totals(r).netExpense, 100000)
        XCTAssertThrowsError(try r.undoBatch(XCTUnwrap(r.batches.first)))
        try r.reviewStatement(s); XCTAssertTrue(s.isReviewed)
        try r.delete(XCTUnwrap(r.entries.first)); XCTAssertFalse(s.isReviewed)
    }
    func testStalePreviewDailyOverlapAndRollback() throws {
        let r = try repo(), p = try preview(r)
        try expense(r, day: "2025-09-15")
        XCTAssertThrowsError(try r.importFile(p)); XCTAssertTrue(r.batches.isEmpty)
        XCTAssertThrowsError(try r.commit {
            r.context.insert(ImportBatch(purpose: "history", digest: "test", sourceName: "rollback"))
            throw LedgerError.invalid("synthetic failure")
        })
        XCTAssertTrue(r.batches.isEmpty)
    }
    func testXLSXMatrixPreviewIgnoresOutsideFormula() throws {
        let data = try TabularFileTests.workbook(sheet: """
        <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>餐饮</t></is></c><c r="C1"><v>25</v></c><c r="U1"><f>999</f><v>999</v></c></row><row r="2"><c r="B2" t="inlineStr"><is><t>超市</t></is></c><c r="C2"><v>0</v></c></row></sheetData><mergeCells><mergeCell ref="A1:A2"/></mergeCells>
        """, shared: "<si><t>日常支出</t></si>")
        let r = try repo(), file = try TabularFile.parse(data: data, name: "matrix.xlsx")
        var m = ImportMapping(); m.firstRow = 1; m.lastRow = 2
        let p = try r.preview(file: file, mapping: m, purpose: .history)
        XCTAssertTrue(p.canCommit); XCTAssertEqual(p.total, 2500)
        try r.importFile(p); XCTAssertEqual(Set(r.histories.map(\.categoryID)), Set([dining, "expense.daily.3"]))
    }
    func testHistoryUndoRefusesModifiedOrReferencedRecords() throws {
        let r = try repo(); try r.importFile(preview(r))
        let batch = try XCTUnwrap(r.batches.first), history = try XCTUnwrap(r.histories.first)
        let original = history.amountCents
        try r.commit { history.amountCents = 123 }
        XCTAssertThrowsError(try r.undoBatch(batch))
        try r.commit { history.amountCents = original }
        _ = try r.saveStatement(month: "2025-09", values: [dining: 120000])
        XCTAssertThrowsError(try r.undoBatch(batch))
    }
    func test1200To1350AdjustmentThenRealEntryRevisesToZero() throws {
        let r = try repo(); try expense(r)
        _ = try r.saveStatement(month: "2026-09", values: [dining: 135000])
        let statement = try XCTUnwrap(r.statements.first)
        let row = try XCTUnwrap(r.differences(for: statement).first { $0.item.categoryID == dining })
        XCTAssertEqual(row.difference, 15000); XCTAssertEqual(try totals(r).netExpense, 120000)
        XCTAssertTrue(try r.differences(for: statement).contains { $0.external == nil && $0.difference == nil })
        XCTAssertThrowsError(try r.reviseAdjustment(itemID: row.id, expectedCents: 15000, reason: " "))
        try r.reviseAdjustment(itemID: row.id, expectedCents: 15000, reason: "missing receipt")
        XCTAssertEqual(try totals(r).netExpense, 135000)
        XCTAssertThrowsError(try r.reviseAdjustment(itemID: row.id, expectedCents: 15000, reason: "repeat"))
        try r.reviewStatement(statement); XCTAssertTrue(statement.isReviewed)
        try expense(r, amount: "150")
        XCTAssertFalse(statement.isReviewed)
        XCTAssertEqual(try r.differences(for: statement).first { $0.id == row.id }?.suggestedAdjustment, 0)
        XCTAssertThrowsError(try r.reviseAdjustment(itemID: row.id, expectedCents: 15000, reason: "stale"))
        try r.reviseAdjustment(itemID: row.id, expectedCents: 0, reason: "receipt recovered")
        XCTAssertEqual(try totals(r).netExpense, 135000)
        XCTAssertEqual(r.adjustments.count, 2); XCTAssertEqual(r.adjustments.filter(\.isActive).count, 1)
        try r.reviewStatement(statement); XCTAssertTrue(statement.isReviewed)
    }
    func testReplacementVersionRetiresAdjustmentsAndKeepsAudit() throws {
        let r = try repo(); try expense(r)
        _ = try r.saveStatement(month: "2026-09", values: [dining: 135000])
        let first = try XCTUnwrap(r.statements.first), item = try XCTUnwrap(r.statementItems.first { $0.amountCents != nil })
        try r.reviseAdjustment(itemID: item.id, expectedCents: 15000, reason: "initial")
        try r.reviewStatement(first)
        _ = try r.saveStatement(month: "2026-09", values: [dining: 140000])
        XCTAssertFalse(first.isActive); XCTAssertFalse(r.adjustments.contains(where: \.isActive))
        XCTAssertEqual(r.statements.first?.version, 2); XCTAssertEqual(try totals(r).netExpense, 120000)
        XCTAssertTrue(r.audits.contains { $0.ownerID == first.id && $0.kind == "review" })
        XCTAssertThrowsError(try r.reviseAdjustment(itemID: item.id, expectedCents: 20000, reason: "old version"))
        XCTAssertThrowsError(try r.saveStatement(month: "2026-09", values: [dining: 140000]))
    }
    func testFileReconciliationDuplicateAndUndo() throws {
        let r = try repo(); try expense(r)
        let p = try preview(r, csv: "大类,分类,金额\n日常支出,餐饮,1350", purpose: .reconciliation, month: "2026-09")
        try r.importFile(p)
        XCTAssertEqual(try totals(r).netExpense, 120000); XCTAssertTrue(r.histories.isEmpty)
        let exported = try preview(r, csv: "大类,分类,金额\n日常支出,餐饮,1350.00", purpose: .reconciliation, month: "2026-09")
        XCTAssertFalse(exported.canCommit)
        let batch = try XCTUnwrap(r.batches.first); try r.undoBatch(batch)
        XCTAssertFalse(r.statements.contains(where: \.isActive)); XCTAssertEqual(r.entries.count, 1)
    }
    func testGrossBasisRefundNegativeDifferenceUnresolvedAndCrossMonthInvalidation() throws {
        let r = try repo(); try expense(r)
        let original = try XCTUnwrap(r.entries.first)
        try r.save(EntryDraft(kind: .refund, amount: "200", day: "2026-09-16", originalEntryID: original.id))
        _ = try r.saveStatement(month: "2026-09", values: [dining: 120000], basis: "grossExpense")
        let gross = try XCTUnwrap(r.statements.first), grossRow = try XCTUnwrap(r.differences(for: gross).first { $0.item.categoryID == dining })
        XCTAssertEqual(grossRow.difference, 0); XCTAssertNil(grossRow.suggestedAdjustment)
        XCTAssertThrowsError(try r.reviseAdjustment(itemID: grossRow.id, expectedCents: 0, reason: "wrong basis"))
        _ = try r.saveStatement(month: "2026-09", values: [dining: 90000])
        let net = try XCTUnwrap(r.statements.first)
        XCTAssertThrowsError(try r.reviewStatement(net))
        try r.reviewStatement(net, unresolvedReason: "awaiting receipts"); XCTAssertTrue(net.isReviewed)
        let refund = try XCTUnwrap(r.entries.first { $0.kind == .refund })
        _ = try r.saveStatement(month: "2026-10", values: [dining: 0]); let october = try XCTUnwrap(r.statements.first)
        try r.reviewStatement(october)
        var draft = r.draft(for: refund); draft.day = "2026-10-02"; try r.save(draft, editingID: refund.id)
        XCTAssertFalse(net.isReviewed); XCTAssertFalse(october.isReviewed)
        XCTAssertEqual(try r.differences(for: october).first { $0.item.categoryID == dining }?.recorded, -20000)
    }
    func testUnsplitHistoryPreventsAdjustmentAndRequiresReviewReason() throws {
        let r = try repo(); try r.importFile(preview(r))
        _ = try r.saveStatement(month: "2025-02", values: [dining: 500])
        let s = try XCTUnwrap(r.statements.first), row = try XCTUnwrap(r.differences(for: s).first { $0.item.categoryID == dining })
        XCTAssertNotNil(row.issue); XCTAssertNil(row.suggestedAdjustment); XCTAssertNil(row.difference)
        XCTAssertThrowsError(try r.reviewStatement(s))
        try r.reviewStatement(s, unresolvedReason: "awaiting monthly split")
    }
    func testMigrationFromV1AndImportAuditSurvivesReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Ledger.store")
        do {
            let schema = Schema(versionedSchema: LedgerSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            context.insert(LedgerEntry(kind: .expense, amountCents: 120000, day: "2026-09-01", categoryID: dining)); try context.save()
        }
        do {
            let r = try LedgerRepository(container: LedgerStore.container(url: url))
            XCTAssertEqual(r.entries.count, 1)
            try r.importFile(preview(r))
            _ = try r.saveStatement(month: "2026-09", values: [dining: 135000])
            let item = try XCTUnwrap(r.statementItems.first { $0.amountCents != nil })
            try r.reviseAdjustment(itemID: item.id, expectedCents: 15000, reason: "persist")
            try r.reviewStatement(XCTUnwrap(r.statements.first))
        }
        let reopened = try LedgerRepository(container: LedgerStore.container(url: url))
        XCTAssertEqual(reopened.histories.count, 2); XCTAssertEqual(reopened.batches.count, 1)
        XCTAssertTrue(reopened.statements.first?.isReviewed == true)
        XCTAssertEqual(try totals(reopened).netExpense, 135000)
        XCTAssertTrue(reopened.audits.contains { $0.kind == "review" }); XCTAssertTrue(reopened.audits.contains { $0.kind == "import" })
    }
}

@MainActor final class ImprovementsTests: XCTestCase {
    private let dining = "expense.daily.2", daily = "expense.daily"
    private func repo(preferences: LedgerPreferences? = nil) throws -> LedgerRepository {
        try LedgerRepository(container: LedgerStore.container(inMemory: true), preferences: preferences)
    }
    private func history(_ r: LedgerRepository, year: Int = 2026) throws -> HistoricalSummary {
        let file = try TabularFile.parse(data: Data("第一分类,年度金额\n日常支出,1000\n总计,1000".utf8), name: "annual.csv")
        var mapping = ImportMapping(); mapping.year = year; mapping.useHistorySheet(file.sheets[0])
        try r.importFile(r.preview(file: file, mapping: mapping, purpose: .history))
        return try XCTUnwrap(r.histories.first)
    }
    private func refund(_ h: HistoricalSummary, amount: String = "100", day: String = "2026-09-02") -> EntryDraft {
        EntryDraft(kind: .refund, amount: amount, day: day, originalEntryID: h.id, refundReference: "receipt-123", refundReason: "退回历史购买商品")
    }
    private func totals(_ r: LedgerRepository, start: String = "2026-01-01", end: String = "2026-12-31") throws -> LedgerTotals {
        try LedgerStatistics.calculate(period: LedgerPeriod(start: start, end: end), entries: r.entries, histories: r.histories, adjustments: r.adjustments, parents: r.categoryParents)
    }
    func testAnnualFirstLevelIncludesHistoryChildrenRefundsAndAdjustments() throws {
        let r = try repo(); let h = try history(r)
        try r.save(EntryDraft(amount: "50", day: "2026-09-01", categoryID: dining))
        let original = try XCTUnwrap(r.entries.first)
        try r.save(EntryDraft(kind: .refund, amount: "10", day: "2026-09-02", originalEntryID: original.id))
        try r.saveStatement(month: "2026-09", values: [dining: 6000])
        let item = try XCTUnwrap(r.statementItems.first { $0.amountCents != nil })
        try r.reviseAdjustment(itemID: item.id, expectedCents: 2000, reason: "缺失单据")
        XCTAssertEqual(try totals(r).byFirstCategory, [daily: 106000])
        try r.save(refund(h, amount: "5"))
        let total = try totals(r)
        XCTAssertEqual(total.byFirstCategory, [daily: 105500])
        XCTAssertEqual(total.byFirstCategory.values.reduce(0, +), total.netExpense)
        XCTAssertEqual(h.amountCents, 100000)
        XCTAssertEqual(try totals(r, start: "2026-09-01", end: "2026-09-30").netExpense, 5500)
        XCTAssertEqual(try totals(r, start: "2026-08-01", end: "2026-08-31").unsplitPeriods.count, 1)
    }
    func testTwoColumnDefaultsAndLegacyChildSourcesAreBothRecognized() throws {
        let r = try repo(); let h = try history(r)
        XCTAssertEqual(h.categoryID, daily); XCTAssertEqual(h.endDay, "2026-08-31")
        let file = try TabularFile.parse(data: Data("大类,分类,金额\n日常支出,餐饮,200\n日常支出,超市,50".utf8), name: "children.csv")
        var mapping = ImportMapping(); mapping.year = 2025; mapping.useHistorySheet(file.sheets[0])
        XCTAssertEqual(mapping.categoryColumn, 1); XCTAssertEqual(mapping.amountColumn, 2)
        XCTAssertEqual(try r.preview(file: file, mapping: mapping, purpose: .history).total, 25000)
        let flat = try TabularFile.parse(data: Data("分类,金额\n日常支出,10".utf8), name: "flat.csv")
        mapping.categoryOverrides = [99: daily]; mapping.useHistorySheet(flat.sheets[0])
        XCTAssertEqual(mapping.parentColumn, 0); XCTAssertEqual(mapping.categoryColumn, -1)
        XCTAssertEqual(mapping.lastRow, 2); XCTAssertTrue(mapping.categoryOverrides.isEmpty)
    }
    func testHistoryRefundRequiresEvidenceDateAndCumulativeLimit() throws {
        let r = try repo(); let h = try history(r)
        var bad = refund(h); bad.refundReference = " "
        XCTAssertThrowsError(try r.save(bad))
        bad = refund(h); bad.refundReason = ""
        XCTAssertThrowsError(try r.save(bad))
        XCTAssertThrowsError(try r.save(refund(h, day: "2026-08-31")))
        try r.save(refund(h))
        XCTAssertThrowsError(try r.save(refund(h, amount: "901")))
        try r.save(refund(h, amount: "900"))
        XCTAssertEqual(try totals(r).netExpense, 0)
        let entry = try XCTUnwrap(r.entries.first)
        var edited = r.draft(for: entry); edited.amount = "901"
        XCTAssertEqual(edited.refundReference, "receipt-123")
        XCTAssertThrowsError(try r.save(edited, editingID: entry.id))
        edited.amount = "50"; edited.refundReason = "修正金额"
        try r.save(edited, editingID: entry.id)
        XCTAssertEqual(r.historicalRefundEvidence(for: entry)?.reason, "修正金额")
        let batch = try XCTUnwrap(r.batches.first)
        XCTAssertThrowsError(try r.undoBatch(batch))
        for entry in r.entries { try r.delete(entry) }
        try r.undoBatch(batch)
        XCTAssertNoThrow(try r.backup())
        XCTAssertThrowsError(try r.save(refund(h)))
    }
    func testHistoryEditRespectsRefundsAndKeepsOldEvidence() throws {
        let r = try repo(), h = try history(r)
        try r.save(refund(h, amount: "100"))
        XCTAssertThrowsError(try r.editHistory(id: h.id, amount: "99", categoryID: h.categoryID, startDay: h.startDay, endDay: h.endDay, expectedRevision: r.revision))
        XCTAssertThrowsError(try r.editHistory(id: h.id, amount: "200", categoryID: dining, startDay: h.startDay, endDay: h.endDay, expectedRevision: r.revision))
        XCTAssertThrowsError(try r.editHistory(id: h.id, amount: "200", categoryID: h.categoryID, startDay: h.startDay, endDay: "2026-09-30", expectedRevision: r.revision))
        try r.editHistory(id: h.id, amount: "200", categoryID: h.categoryID, startDay: h.startDay, endDay: h.endDay, expectedRevision: r.revision)
        XCTAssertEqual(try totals(r).netExpense, 10000)
        let entry = try XCTUnwrap(r.entries.first)
        try r.delete(entry)
        try r.editHistory(id: h.id, amount: "0", categoryID: dining, startDay: "2024-01-01", endDay: "2024-12-31", expectedRevision: r.revision)
        XCTAssertNoThrow(try r.backup().encoded())
    }
    func testHistoricalRefundBackupRoundTripAuditAndExport() throws {
        let r = try repo(); let h = try history(r)
        try r.save(refund(h))
        let backup = try r.backup(); XCTAssertEqual(backup.version, 2)
        let bytes = try backup.encoded(), decoded = try LedgerBackup.decode(bytes)
        let target = try repo(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try target.restore(decoded, expectedRevision: target.revision, directory: folder)
        XCTAssertEqual(try totals(target).netExpense, 90000)
        XCTAssertEqual(target.historicalRefundEvidence(for: try XCTUnwrap(target.entries.first))?.reference, "receipt-123")
        let csv = try target.csv(kind: .entries, period: LedgerPeriod(start: "2026-09-01", end: "2026-09-30"))
        let text = String(decoding: csv.data, as: UTF8.self)
        XCTAssertTrue(text.contains("历史汇总")); XCTAssertTrue(text.contains("receipt-123")); XCTAssertTrue(text.contains(h.batchID!))
        var bad = backup; bad.version = 1; XCTAssertThrowsError(try bad.validate())
        bad = backup; bad.audits.removeAll { $0.kind == "historicalRefund" }; XCTAssertThrowsError(try bad.validate())
        bad = backup; bad.entries[0].day = "2026-08-31"; XCTAssertThrowsError(try bad.validate())
        bad = backup; bad.histories[0].isActive = false; XCTAssertThrowsError(try bad.validate())
        bad = backup; bad.entries[0].amountCents = 100001; XCTAssertThrowsError(try bad.validate())
    }
    func testHistoryRefundInvalidatesReviewAndBlocksChildAdjustment() throws {
        let r = try repo(); let h = try history(r)
        try r.saveStatement(month: "2026-09", values: [dining: 1000])
        let statement = try XCTUnwrap(r.statements.first), item = try XCTUnwrap(r.statementItems.first { $0.amountCents != nil })
        try r.reviseAdjustment(itemID: item.id, expectedCents: 1000, reason: "先前缺失")
        try r.reviewStatement(statement)
        try r.save(refund(h))
        XCTAssertFalse(statement.isReviewed)
        let row = try XCTUnwrap(r.differences(for: statement).first { $0.id == item.id })
        XCTAssertNotNil(row.issue); XCTAssertNil(row.suggestedAdjustment)
        XCTAssertThrowsError(try r.reviseAdjustment(itemID: item.id, expectedCents: -1000, reason: "不可分摊"))
        try r.reviseAdjustment(itemID: item.id, expectedCents: 0, reason: "清理旧调整")
        XCTAssertThrowsError(try r.reviewStatement(statement))
        try r.reviewStatement(statement, unresolvedReason: "历史退款只按大类记录")
        let entry = try XCTUnwrap(r.entries.first)
        var edited = r.draft(for: entry); edited.day = "2026-10-01"
        try r.saveStatement(month: "2026-10", values: [dining: 0])
        let october = try XCTUnwrap(r.statements.first { $0.month == "2026-10" })
        try r.reviewStatement(october)
        try r.save(edited, editingID: entry.id)
        XCTAssertFalse(statement.isReviewed); XCTAssertFalse(october.isReviewed)
    }
    func testCoverageDistinguishesHistoryMissingPartialAndReviewed() throws {
        let r = try repo(); _ = try history(r)
        let august = try XCTUnwrap(r.coverage(month: "2026-08").first { $0.id == daily })
        XCTAssertEqual(august.status, "历史未按月拆分"); XCTAssertFalse(august.hasEntries)
        let september = try XCTUnwrap(r.coverage(month: "2026-09").first { $0.id == daily })
        XCTAssertEqual(september.status, "未提供依据")
        try r.saveStatement(month: "2026-09", values: [dining: 0])
        let statement = try XCTUnwrap(r.statements.first)
        let before = try XCTUnwrap(r.coverage(month: "2026-09").first { $0.id == daily })
        XCTAssertEqual(before.supplied, 1); XCTAssertEqual(before.expected, 11); XCTAssertFalse(before.reviewed)
        try r.reviewStatement(statement)
        let after = try XCTUnwrap(r.coverage(month: "2026-09").first { $0.id == daily })
        XCTAssertEqual(after.status, "已核对 · 1/11 个分类")
        XCTAssertEqual(try r.coverage(month: "2026-09").first { $0.id == "expense.clothing" }?.status, "未提供依据")
    }
    func testBackupStampTracksExportedSnapshotAndPersistsDelta() throws {
        let suite = "Improvements-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = LedgerPreferences(scope: "test", defaults: defaults), r = try repo(preferences: prefs)
        XCTAssertTrue(prefs.backupDue()); XCTAssertNil(try prefs.changes(in: r.backup()))
        try r.save(EntryDraft(amount: "10", day: "2026-09-01", categoryID: dining))
        let snapshot = try r.backup(), exported = Date()
        // Ledger changes while the file picker is open must remain outside the saved snapshot.
        try r.save(EntryDraft(amount: "20", day: "2026-09-02", categoryID: dining))
        try prefs.recordExport(snapshot, at: exported)
        XCTAssertEqual(try prefs.changes(in: r.backup()), BackupDelta(added: 1))
        XCTAssertFalse(prefs.backupDue(now: exported)); XCTAssertTrue(prefs.backupDue(now: exported.addingTimeInterval(8 * 86400)))
        let reopened = LedgerPreferences(scope: "test", defaults: defaults)
        XCTAssertEqual(reopened.backupStamp?.exportedAt, exported)
        let original = try XCTUnwrap(r.entries.first { $0.day == "2026-09-01" })
        var draft = r.draft(for: original); draft.amount = "15"; try r.save(draft, editingID: original.id)
        XCTAssertEqual(try reopened.changes(in: r.backup()), BackupDelta(added: 1, changed: 1))
        try r.delete(original)
        XCTAssertEqual(try reopened.changes(in: r.backup()), BackupDelta(added: 1, removed: 1))
        reopened.reminderDays = 0; XCTAssertFalse(reopened.backupDue(now: exported.addingTimeInterval(100 * 86400)))
    }
    func testRestoreRehearsalDoesNotReplaceCurrentLedgerOrBackupStamp() throws {
        let source = try repo(); let h = try history(source); try source.save(refund(h))
        let r = try repo(); try r.save(EntryDraft(amount: "7", day: "2026-10-01", categoryID: dining))
        let before = try r.backup(), revision = r.revision
        try r.rehearseRestore(source.backup())
        XCTAssertEqual(r.revision, revision); XCTAssertEqual(try r.backup().entries, before.entries)
        XCTAssertTrue(r.histories.isEmpty); XCTAssertNil(r.preferences.backupStamp); XCTAssertNotNil(r.preferences.rehearsedAt)
    }
    func testQuickDefaultsTemplatesAndSortingRespectArchivedCategories() throws {
        let r = try repo(); try r.saveAccount(name: "现金")
        let account = try XCTUnwrap(r.accounts.first)
        let draft = EntryDraft(amount: "15", day: "2026-09-01", categoryID: dining, accountID: account.id, note: "固定午餐")
        r.remember(draft); try r.saveTemplate(draft)
        XCTAssertEqual(r.quickDraft().accountID, account.id); XCTAssertEqual(r.quickDraft().categoryID, dining)
        let template = try XCTUnwrap(r.preferences.templates.first)
        XCTAssertEqual(r.draft(from: template).note, "固定午餐")
        XCTAssertEqual(r.draft(from: template).day, LedgerDay(date: Date()).rawValue)
        let ids = r.categories.filter { $0.parentID == daily }.map(\.id).reversed()
        try r.reorderCategories(Array(ids), parentID: daily, kind: .expense)
        XCTAssertEqual(r.categories.filter { $0.parentID == daily }.map(\.id), Array(ids))
        XCTAssertThrowsError(try r.reorderCategories([dining], parentID: daily, kind: .expense))
        try r.saveAccount(id: account.id, name: account.name, archived: true)
        try r.saveCategory(id: dining, name: "餐饮", parentID: daily, kind: .expense, archived: true)
        XCTAssertNil(r.quickDraft().accountID); XCTAssertNotEqual(r.quickDraft().categoryID, dining)
        XCTAssertNil(r.draft(from: template).categoryID); XCTAssertNil(r.draft(from: template).accountID)
        XCTAssertNoThrow(try r.backup())
    }
}

import XCTest
import SwiftData
@testable import LotBill

final class LedgerRulesTests: XCTestCase {
    func testMoneyPrecisionAndInvalidInput() throws {
        XCTAssertEqual(try Money.parse("0.10") + Money.parse("0.20"), 30)
        XCTAssertEqual(try Money.parse(" 12.3 "), 1230)
        XCTAssertEqual(try Money.parse("0", allowZero: true), 0)
        for text in ["", "0", "-1", "1.001", "1e3", "1,000", "NaN", "10000000001"] {
            XCTAssertThrowsError(try Money.parse(text), text)
        }
        XCTAssertEqual(Money.decimal(-35), "-0.35")
        XCTAssertThrowsError(try Money.add(Int64.max, 1))
        XCTAssertThrowsError(try Money.subtract(0, Int64.min))
    }
    func testCalendarAndInclusivePeriods() throws {
        XCTAssertThrowsError(try LedgerDay("2025-02-29"))
        XCTAssertThrowsError(try LedgerDay("2026-13-01"))
        XCTAssertEqual(try LedgerDay("2024-02-29").month, "2024-02")
        let a = try LedgerPeriod(start: "2026-01-01", end: "2026-08-31")
        let b = try LedgerPeriod(start: "2026-08-31", end: "2026-09-30")
        XCTAssertTrue(a.overlaps(b))
        XCTAssertFalse(a.contains(b))
        XCTAssertEqual(LedgerPeriod.month(containing: try LedgerDay("2024-02-15").date()).end.rawValue, "2024-02-29")
        let instant = ISO8601DateFormatter().date(from: "2026-09-30T23:30:00Z")!
        XCTAssertEqual(LedgerDay(date: instant, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!).rawValue, "2026-10-01")
        XCTAssertEqual(LedgerDay(date: instant, timeZone: TimeZone(secondsFromGMT: 0)!).rawValue, "2026-09-30")
    }
}

@MainActor final class LedgerRepositoryTests: XCTestCase {
    private let dining = "expense.daily.2"
    private func repository() throws -> LedgerRepository { try LedgerRepository(container: LedgerStore.container(inMemory: true)) }
    private func expense(_ amount: String = "35.50", day: String = "2026-09-15") -> EntryDraft {
        EntryDraft(amount: amount, day: day, categoryID: dining, note: "Synthetic lunch")
    }
    private func totals(_ repository: LedgerRepository, month: String) throws -> LedgerTotals {
        try LedgerStatistics.calculate(period: .month(containing: LedgerDay(month + "-15").date()), entries: repository.entries)
    }
    func testSeedIDsAreStableAndNoAccountsAreInvented() throws {
        let container = try LedgerStore.container(inMemory: true)
        let first = try LedgerRepository(container: container)
        XCTAssertEqual(first.categories.filter { $0.kindRaw == "expense" && $0.parentID == nil }.count, 5)
        XCTAssertEqual(first.categories.filter { $0.parentID != nil }.count, 27)
        XCTAssertTrue(first.accounts.isEmpty)
        let ids = Set(first.categories.map(\.id))
        let second = try LedgerRepository(container: container)
        XCTAssertEqual(Set(second.categories.map(\.id)), ids)
        XCTAssertEqual(second.categories.count, 33)
    }
    func testEditorOptionsPreserveArchivedEditAndRefreshLabels() throws {
        let repository = try repository()
        try repository.saveAccount(name: "Cash")
        let account = try XCTUnwrap(repository.accounts.first)
        var draft = expense(); draft.accountID = account.id
        try repository.save(draft)
        let entry = try XCTUnwrap(repository.entries.first)
        let original = EntryEditorOptions(repository: repository, kind: .expense, entry: nil)
        try repository.saveCategory(id: dining, name: "Renamed", parentID: "expense.daily", kind: .expense, archived: true)
        try repository.saveAccount(id: account.id, name: "Old cash", archived: true)
        let fresh = EntryEditorOptions(repository: repository, kind: .expense, entry: nil)
        XCTAssertFalse(fresh.categories.contains { $0.id == dining })
        XCTAssertTrue(fresh.accounts.isEmpty)
        let editing = EntryEditorOptions(repository: repository, kind: .expense, entry: entry)
        XCTAssertEqual(editing.categories.first { $0.id == dining }?.title, "日常支出 · Renamed（停用）")
        XCTAssertEqual(editing.accounts.first?.title, "Old cash（停用）")
        XCTAssertEqual(original.categories.first { $0.id == dining }?.name, "餐饮")
        XCTAssertTrue(original.refundSources.isEmpty)
        XCTAssertEqual(EntryEditorOptions(repository: repository, kind: .refund, entry: nil).refundSources.map(\.id), [entry.id])
        XCTAssertTrue(EntryEditorOptions(repository: repository, kind: .income, entry: nil).categories.allSatisfy { $0.id.hasPrefix("income.") })
        try repository.saveCategory(id: "expense.daily", name: "日常支出", parentID: nil, kind: .expense, archived: true)
        XCTAssertFalse(repository.selectableCategories(for: .expense).contains { $0.parentID == "expense.daily" })
    }

    func testEditorOptionsWithLargeCategoryCatalog() throws {
        let repository = try repository()
        try repository.commit {
            for index in 0..<500 {
                repository.context.insert(LedgerCategory(id: "scale.\(index)", name: "Category \(index)", kind: .expense, sortOrder: 2000 + index))
            }
        }
        let start = Date()
        let options = EntryEditorOptions(repository: repository, kind: .expense, entry: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(options.categories.count, 527)
        // A broad regression guard: rebuilding the old nested scan at this scale
        // stalls the main thread for seconds. Normal typing uses this value snapshot.
        XCTAssertLessThan(elapsed, 1.0)
        print("Editor options: 533 categories, \(elapsed) seconds")
    }

    func testCRUDMovesBothMonthlyTotalsAndInvalidatesReconciliation() throws {
        let container = try LedgerStore.container(inMemory: true)
        let context = ModelContext(container)
        let september = ReconciliationStatement(month: "2026-09")
        let october = ReconciliationStatement(month: "2026-10")
        let november = ReconciliationStatement(month: "2026-11")
        september.isReviewed = true; october.isReviewed = true
        november.isReviewed = true
        context.insert(september); context.insert(october); context.insert(november); try context.save()
        let repository = try LedgerRepository(container: container)
        try repository.save(expense())
        let id = try XCTUnwrap(repository.entries.first?.id)
        XCTAssertEqual(try totals(repository, month: "2026-09").netExpense, 3550)
        try repository.save(expense("40.25", day: "2026-10-02"), editingID: id)
        XCTAssertEqual(try totals(repository, month: "2026-09").netExpense, 0)
        XCTAssertEqual(try totals(repository, month: "2026-10").netExpense, 4025)
        let statements = try ModelContext(container).fetch(FetchDescriptor<ReconciliationStatement>())
        XCTAssertTrue(statements.filter { $0.month != "2026-11" }.allSatisfy { !$0.isReviewed })
        XCTAssertEqual(statements.first { $0.month == "2026-11" }?.isReviewed, true)
        try repository.delete(try XCTUnwrap(repository.entries.first))
        XCTAssertEqual(try totals(repository, month: "2026-10").netExpense, 0)
    }
    func testInvalidEditLeavesEntryUnchanged() throws {
        let repository = try repository()
        try repository.save(expense())
        let entry = try XCTUnwrap(repository.entries.first)
        XCTAssertThrowsError(try repository.save(expense("-5"), editingID: entry.id))
        XCTAssertEqual(entry.amountCents, 3550)
        XCTAssertEqual(repository.entries.count, 1)
        var wrong = expense(); wrong.categoryID = "income.other"
        XCTAssertThrowsError(try repository.save(wrong))
    }
    func testMovingCategoryRecomputesDistributionWithoutChangingIdentity() throws {
        let repository = try repository()
        try repository.save(expense())
        let id = try XCTUnwrap(repository.entries.first?.id)
        var changed = expense(); changed.categoryID = "expense.daily.3"
        try repository.save(changed, editingID: id)
        let result = try totals(repository, month: "2026-09")
        XCTAssertNil(result.byCategory[dining])
        XCTAssertEqual(result.byCategory["expense.daily.3"], 3550)
        XCTAssertEqual(repository.entries.first?.id, id)
    }
    func testTransferRequiresDifferentAccountsAndNeverCountsAsIncome() throws {
        let repository = try repository()
        try repository.saveAccount(name: "Synthetic cash")
        try repository.saveAccount(name: "Synthetic bank")
        let from = repository.accounts[0].id, to = repository.accounts[1].id
        var draft = EntryDraft(kind: .transfer, amount: "500", day: "2026-09-01", accountID: from, destinationAccountID: from)
        XCTAssertThrowsError(try repository.save(draft))
        draft.destinationAccountID = to
        try repository.save(draft)
        let result = try totals(repository, month: "2026-09")
        XCTAssertEqual(result.income, 0); XCTAssertEqual(result.netExpense, 0)
        XCTAssertEqual(repository.entries.first?.destinationAccountID, to)
    }
    func testRefundLimitDateAndSourceProtection() throws {
        let repository = try repository()
        try repository.save(expense("100"))
        let original = try XCTUnwrap(repository.entries.first)
        var refund = EntryDraft(kind: .refund, amount: "30", day: "2026-10-01", originalEntryID: original.id)
        try repository.save(refund)
        XCTAssertEqual(try totals(repository, month: "2026-09").netExpense, 10000)
        XCTAssertEqual(try totals(repository, month: "2026-10").netExpense, -3000)
        XCTAssertEqual(repository.entries.first?.categoryID, dining)
        refund.amount = "71"; XCTAssertThrowsError(try repository.save(refund))
        refund.amount = "1"; refund.day = "2026-09-01"; XCTAssertThrowsError(try repository.save(refund))
        XCTAssertThrowsError(try repository.delete(original))
        XCTAssertThrowsError(try repository.save(expense("20"), editingID: original.id))
        let savedRefund = try XCTUnwrap(repository.entries.first(where: { $0.kind == .refund }))
        refund.day = "2026-10-01"; refund.amount = "100"
        try repository.save(refund, editingID: savedRefund.id)
        XCTAssertEqual(try totals(repository, month: "2026-10").refunds, 10000)
        XCTAssertThrowsError(try repository.save(EntryDraft(kind: .refund, amount: "1", day: "2026-10-02", originalEntryID: original.id)))
    }
    func testCategoryRenamePreservesReferencesAndArchivedCategoryIsNotSelectable() throws {
        let repository = try repository()
        try repository.save(expense())
        try repository.saveCategory(id: dining, name: "吃饭", parentID: "expense.daily", kind: .expense, archived: true)
        XCTAssertEqual(repository.entries.first?.categoryID, dining)
        XCTAssertEqual(repository.categoryName(dining), "吃饭")
        XCTAssertFalse(repository.selectableCategories(for: .expense).contains { $0.id == dining })
        XCTAssertThrowsError(try repository.save(expense()))
        try repository.save(expense("40"), editingID: repository.entries.first?.id)
        XCTAssertEqual(repository.entries.first?.amountCents, 4000)
    }
    func testReferencedIncomeCategoryCannotBecomeParent() throws {
        let repository = try repository()
        try repository.save(EntryDraft(kind: .income, amount: "100", day: "2026-09-01", categoryID: "income.other"))
        XCTAssertThrowsError(try repository.saveCategory(name: "新的收入子类", parentID: "income.other", kind: .income))
    }
    func testAccountRenameArchiveAndDanglingIDValidation() throws {
        let repository = try repository()
        try repository.saveAccount(name: "Cash")
        let id = repository.accounts[0].id
        var draft = expense(); draft.accountID = id
        try repository.save(draft)
        try repository.saveAccount(id: id, name: "现金", archived: true)
        XCTAssertEqual(repository.accountName(repository.entries[0].accountID), "现金")
        XCTAssertThrowsError(try repository.save(draft))
        XCTAssertThrowsError(try repository.saveAccount(id: "missing", name: "invalid"))
        XCTAssertThrowsError(try repository.saveCategory(id: "missing", name: "invalid", parentID: nil, kind: .income))
    }
    func testDiskPersistenceAndSeedRenameAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Ledger.store")
        var savedID = ""
        do {
            let repository = try LedgerRepository(container: LedgerStore.container(url: url))
            try repository.save(expense())
            savedID = try XCTUnwrap(repository.entries.first?.id)
            try repository.saveCategory(id: dining, name: "饭钱", parentID: "expense.daily", kind: .expense)
        }
        let reopened = try LedgerRepository(container: LedgerStore.container(url: url))
        XCTAssertEqual(reopened.entries.first?.id, savedID)
        XCTAssertEqual(reopened.entries.first?.amountCents, 3550)
        XCTAssertEqual(reopened.categoryName(dining), "饭钱")
        XCTAssertEqual(reopened.categories.count, 33)
    }
    func testDailyEntryCannotDoubleCountHistory() throws {
        let container = try LedgerStore.container(inMemory: true)
        let context = ModelContext(container)
        context.insert(HistoricalSummary(startDay: "2026-09-01", endDay: "2026-09-30", precision: "month", categoryID: dining, kind: .expense, amountCents: 10000))
        try context.save()
        let repository = try LedgerRepository(container: container)
        XCTAssertThrowsError(try repository.save(expense()))
        XCTAssertTrue(repository.entries.isEmpty)
    }
}

@MainActor final class LedgerStatisticsTests: XCTestCase {
    func testHistoryPrecisionMustMatchActualRange() throws {
        let history = HistoricalSummary(startDay: "2026-01-01", endDay: "2026-08-31", precision: "month", categoryID: "dining", kind: .expense, amountCents: 80000)
        let period = LedgerPeriod.year(containing: try LedgerDay("2026-01-01").date())
        XCTAssertThrowsError(try LedgerStatistics.calculate(period: period, entries: [], histories: [history]))
        history.precision = "range"
        XCTAssertEqual(try LedgerStatistics.calculate(period: period, entries: [], histories: [history]).netExpense, 80000)
    }
    func testUnsplitHistoryIsNotInventedAsMonthlyAmount() throws {
        let history = HistoricalSummary(startDay: "2026-01-01", endDay: "2026-08-31", precision: "range", categoryID: "dining", kind: .expense, amountCents: 80000)
        let monthly = try LedgerStatistics.calculate(period: .month(containing: LedgerDay("2026-08-10").date()), entries: [], histories: [history])
        XCTAssertEqual(monthly.consumption, 0)
        XCTAssertEqual(monthly.unsplitPeriods, ["2026-01-01 至 2026-08-31"])
        let annual = try LedgerStatistics.calculate(period: .year(containing: LedgerDay("2026-08-10").date()), entries: [], histories: [history])
        XCTAssertEqual(annual.consumption, 80000); XCTAssertTrue(annual.unsplitPeriods.isEmpty)
    }
    func testOverlapHistoryAndDetailOrHistoryIsRejected() throws {
        let history = HistoricalSummary(startDay: "2026-01-01", endDay: "2026-08-31", precision: "range", categoryID: "dining", kind: .expense, amountCents: 80000)
        let entry = LedgerEntry(kind: .expense, amountCents: 100, day: "2026-08-31", categoryID: "dining")
        let period = LedgerPeriod.year(containing: try LedgerDay("2026-01-01").date())
        XCTAssertThrowsError(try LedgerStatistics.calculate(period: period, entries: [entry], histories: [history]))
        let other = HistoricalSummary(startDay: "2026-08-01", endDay: "2026-08-31", precision: "month", categoryID: "dining", kind: .expense, amountCents: 100)
        XCTAssertThrowsError(try LedgerStatistics.calculate(period: period, entries: [], histories: [history, other]))
    }
    func testMonthlyStatementDoesNotCountAndAdjustmentsDoNotDuplicate() throws {
        let period = LedgerPeriod.month(containing: try LedgerDay("2026-09-01").date())
        let entry = LedgerEntry(kind: .expense, amountCents: 120000, day: "2026-09-10", categoryID: "dining")
        let statement = ReconciliationStatement(month: "2026-09")
        let item = ReconciliationItem(statementID: statement.id, categoryID: "dining", amountCents: 135000)
        let base = try LedgerStatistics.calculate(period: period, entries: [entry])
        XCTAssertEqual(base.netExpense, 120000)
        XCTAssertEqual((item.amountCents ?? 0) - base.netExpense, 15000)
        let adjustment = MonthlyAdjustment(month: "2026-09", categoryID: "dining", signedCents: 15000, reason: "合成补差", statementItemID: item.id)
        XCTAssertEqual(try LedgerStatistics.calculate(period: period, entries: [entry], adjustments: [adjustment]).netExpense, 135000)
        XCTAssertThrowsError(try LedgerStatistics.calculate(period: period, entries: [entry], adjustments: [adjustment, adjustment]))
        let missing = ReconciliationItem(statementID: statement.id, categoryID: "missing", amountCents: nil)
        XCTAssertNil(missing.amountCents)
        let zero = ReconciliationItem(statementID: statement.id, categoryID: "zero", amountCents: 0)
        XCTAssertEqual(zero.amountCents, 0)
    }
}

@MainActor final class LedgerEntryFilterTests: XCTestCase {
    func testParentCategoryPeriodAndTransferDestinationFilters() throws {
        let repo = try LedgerRepository(container: LedgerStore.container(inMemory: true))
        try repo.saveAccount(name: "Synthetic source")
        try repo.saveAccount(name: "Synthetic destination")
        let source = try XCTUnwrap(repo.accounts.first { $0.name == "Synthetic source" })
        let destination = try XCTUnwrap(repo.accounts.first { $0.name == "Synthetic destination" })
        try repo.save(EntryDraft(amount: "12.34", day: "2026-09-10", categoryID: "expense.daily.2", note: "Synthetic meal"), editingID: nil)
        var transfer = EntryDraft(amount: "50", day: "2026-09-11")
        transfer.kind = .transfer; transfer.accountID = source.id; transfer.destinationAccountID = destination.id
        try repo.save(transfer, editingID: nil)
        try repo.save(EntryDraft(amount: "2", day: "2026-10-01", categoryID: "expense.daily.2"), editingID: nil)
        let period = try LedgerPeriod(start: "2026-09-01", end: "2026-09-30")
        let parent = try XCTUnwrap(repo.categoryParents["expense.daily.2"])
        XCTAssertEqual(repo.filteredEntries(period: period, kind: "expense", category: parent, account: "all", search: "12.34").map(\.note), ["Synthetic meal"])
        XCTAssertEqual(repo.filteredEntries(period: period, kind: "all", category: "all", account: destination.id, search: "destination").map(\.kind), [.transfer])
        XCTAssertEqual(repo.filteredEntries(period: period, kind: "all", category: "all", account: "all", search: "").count, 2)
        XCTAssertTrue(repo.filteredEntries(period: period, kind: "income", category: "all", account: "all", search: "").isEmpty)
    }
}

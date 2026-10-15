import Foundation

enum ImportPurpose: String, CaseIterable, Identifiable, Sendable {
    case history, reconciliation
    var id: String { rawValue }
    var title: String { self == .history ? "历史汇总" : "月度对账" }
}
enum AmountFormat: String, CaseIterable, Identifiable, Sendable {
    case decimalPoint, decimalComma
    var id: String { rawValue }
    var title: String { self == .decimalPoint ? "1,234.56（点作小数）" : "1.234,56（逗号作小数）" }
    func parse(_ text: String, signed: Bool = false) throws -> Int64? {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return nil }
        if clean.hasPrefix("¥") || clean.hasPrefix("￥") { clean.removeFirst(); clean = clean.trimmingCharacters(in: .whitespaces) }
        var negative = false
        if signed && clean.hasPrefix("-") { negative = true; clean.removeFirst() }
        let pattern = self == .decimalPoint ? #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"# : #"^(?:[0-9]+|[0-9]{1,3}(?:\.[0-9]{3})+)(?:,[0-9]{1,2})?$"#
        guard clean.range(of: pattern, options: .regularExpression) != nil else { throw LedgerError.invalid("金额格式或小数精度无效，请核对分隔符。") }
        if self == .decimalPoint { clean = clean.replacingOccurrences(of: ",", with: "") }
        else { clean = clean.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        let value = try Money.parse(clean, allowZero: true)
        return negative ? -value : value
    }
}
struct ImportMapping: Sendable, Equatable {
    var sheetIndex = 0
    var firstRow = 2
    var lastRow = 100
    // History: required first-level category column. Reconciliation: -1 means a flat category column.
    var parentColumn = 0
    // Optional second-level column (-1 = a first-level summary).
    var categoryColumn = 1
    // History reads one annual total column, without allocating amounts to individual months.
    var amountColumn = 2
    var precision: PeriodPrecision = .year
    var year = Calendar(identifier: .gregorian).component(.year, from: Date()) - 1
    var startDay = "2026-09-01"
    var endDay = "2026-09-30"
    var amountFormat: AmountFormat = .decimalPoint
    var basis = "netExpense"
    var categoryOverrides: [Int: String] = [:]

    mutating func useHistorySheet(_ sheet: ImportSheet) {
        firstRow = min(2, max(1, sheet.rows.count)); lastRow = max(1, sheet.rows.count)
        categoryOverrides = [:]
        let headers = (0..<sheet.columnCount).map { sheet.cell(row: 1, column: $0).text.trimmingCharacters(in: .whitespacesAndNewlines) }
        parentColumn = headers.firstIndex { ["大类", "第一分类", "一级分类"].contains($0) } ?? 0
        categoryColumn = headers.firstIndex { ["子类", "第二分类", "二级分类", "分类"].contains($0) && sheet.columnCount > 2 } ?? (sheet.columnCount >= 3 ? 1 : -1)
        amountColumn = headers.firstIndex { ["金额", "年度金额", "年汇总", "年度支出", "合计"].contains($0) } ?? (sheet.columnCount == 2 ? 1 : 2)
        if categoryColumn == parentColumn || categoryColumn == amountColumn { categoryColumn = -1 }
        if let sheetYear = Int(sheet.name.trimmingCharacters(in: .whitespacesAndNewlines)), (1900...2100).contains(sheetYear) { year = sheetYear }
    }
    var historyPeriodLabel: String { year == 2026 ? "2026 年度（截至 8 月 31 日）" : "\(year) 年度" }
    struct HistoryColumn {
        let column: Int
        let label: String
        let period: LedgerPeriod
        // A partial annual total uses the existing range representation for statistics and backups.
        var precision: PeriodPrecision { period.end.rawValue.hasSuffix("-12-31") ? .year : .range }
    }
    func historyColumns() throws -> [HistoryColumn] {
        guard (1900...2100).contains(year) else { throw LedgerError.invalid("请填写 1900–2100 之间的年份。") }
        guard precision == .year else { throw LedgerError.invalid("历史导入仅支持年度汇总；2026 年数据截至 8 月 31 日，不导入月度汇总。") }
        let end = year == 2026 ? "2026-08-31" : "\(year)-12-31"
        return [HistoryColumn(column: amountColumn, label: historyPeriodLabel, period: try LedgerPeriod(start: "\(year)-01-01", end: end))]
    }
}
struct ImportCandidate: Identifiable, Codable, Sendable {
    let row: Int
    let sourceCategory: String
    let categoryID: String?
    let amountCents: Int64?
    let formula: Bool
    var issue: String?
    let isTotal: Bool
    var period: String? = nil
    var note: String? = nil
    var id: String { "\(row)|\(period ?? "")" }
}
/// One history record the import will create, preserving the supplied category level.
struct ImportSummaryLine: Identifiable, Sendable {
    let categoryID: String
    let period: String
    let startDay: String
    let endDay: String
    let precision: PeriodPrecision
    let amountCents: Int64?
    var issue: String?
    var note: String?
    var warning: String?
    var id: String { categoryID + "|" + period }
}
struct ImportPreview {
    let file: ImportFile
    let mapping: ImportMapping
    let purpose: ImportPurpose
    var rows: [ImportCandidate]
    var summaries: [ImportSummaryLine] = []
    var issues: [String]
    var total: Int64
    var newCategories: [ImportCategory] = []
    var canCommit: Bool {
        guard issues.isEmpty, !rows.contains(where: { $0.issue != nil }) else { return false }
        if purpose == .history { return !summaries.contains { $0.issue != nil } && summaries.contains { $0.amountCents != nil } }
        return rows.contains { !$0.isTotal && $0.amountCents != nil }
    }
}
struct ImportCategory: Identifiable {
    let id: String
    let name: String
    let parentID: String
}

struct HistoryEdit: Codable {
    let before: ImportedHistorySnapshot
    let after: ImportedHistorySnapshot
}
struct ImportedHistorySnapshot: Codable, Hashable {
    let id: String
    let start: String
    let end: String
    let precision: String
    let category: String
    let kind: String
    let currency: String
    let amount: Int64
    @MainActor init(_ h: HistoricalSummary) {
        id = h.id; start = h.startDay; end = h.endDay; precision = h.precision
        category = h.categoryID; kind = h.kindRaw; currency = h.currency; amount = h.amountCents
    }
}
struct ImportReceipt: Codable {
    let sheet: String
    let rows: [ImportCandidate]
    let history: [ImportedHistorySnapshot]
    let statementID: String?
}

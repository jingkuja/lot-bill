import Foundation

enum LedgerError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case expense, income, transfer, refund
    var id: String { rawValue }
    var title: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转账"
        case .refund: "退款"
        }
    }
    var symbol: String {
        switch self {
        case .expense: "arrow.up.right"
        case .income: "arrow.down.left"
        case .transfer: "arrow.left.arrow.right"
        case .refund: "arrow.uturn.backward"
        }
    }
}

enum Money {
    // Maximum individual entry: RMB 10 billion. Totals use checked arithmetic.
    static let maximum: Int64 = 1_000_000_000_000

    static func parse(_ text: String, allowZero: Bool = false) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]{1,11}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else {
            throw LedgerError.invalid("请输入最多两位小数的金额，例如 35.50。")
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int64(parts[0]) else { throw LedgerError.invalid("金额超出范围。") }
        let fraction = parts.count == 2 ? String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
        let cents = whole * 100 + (Int64(fraction) ?? 0)
        guard cents <= maximum, cents > 0 || (allowZero && cents == 0) else {
            throw LedgerError.invalid("金额必须大于零且不超过 100 亿元。")
        }
        return cents
    }

    static func decimal(_ cents: Int64) -> String {
        let magnitude = cents.magnitude
        return "\(cents < 0 ? "-" : "")\(magnitude / 100).\(String(format: "%02llu", magnitude % 100))"
    }
    static func display(_ cents: Int64) -> String { "¥" + decimal(cents) }
    static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw LedgerError.invalid("合计超出可计算范围。") }
        return result
    }
    static func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else { throw LedgerError.invalid("合计超出可计算范围。") }
        return result
    }
}

struct LedgerDay: Hashable, Comparable, Codable {
    let rawValue: String
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    init(_ raw: String) throws {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard raw.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              parts.count == 3, (1900...2100).contains(parts[0]),
              let date = Self.utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            throw LedgerError.invalid("日期格式应为有效的 YYYY-MM-DD。")
        }
        let c = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard c.year == parts[0], c.month == parts[1], c.day == parts[2] else {
            throw LedgerError.invalid("日期不存在。")
        }
        rawValue = raw
    }
    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        rawValue = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    func date(timeZone: TimeZone = .current) -> Date {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }
    var month: String { String(rawValue.prefix(7)) }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct LedgerPeriod: Equatable {
    let start: LedgerDay
    let end: LedgerDay
    init(start: String, end: String) throws {
        self.start = try LedgerDay(start)
        self.end = try LedgerDay(end)
        guard self.start <= self.end else { throw LedgerError.invalid("期间起始日不能晚于结束日。") }
    }
    static func month(containing date: Date) -> Self {
        let month = LedgerDay(date: date).month
        let start = try! LedgerDay(month + "-01")
        let firstUTC = start.date(timeZone: TimeZone(secondsFromGMT: 0)!)
        let next = LedgerDay.utcCalendar.date(byAdding: .month, value: 1, to: firstUTC)!
        let last = LedgerDay.utcCalendar.date(byAdding: .day, value: -1, to: next)!
        return try! Self(start: start.rawValue, end: LedgerDay(date: last, timeZone: TimeZone(secondsFromGMT: 0)!).rawValue)
    }
    static func year(containing date: Date) -> Self {
        let year = LedgerDay(date: date).rawValue.prefix(4)
        return try! Self(start: "\(year)-01-01", end: "\(year)-12-31")
    }
    func contains(_ day: String) -> Bool { start.rawValue <= day && day <= end.rawValue }
    func contains(_ other: Self) -> Bool { start <= other.start && end >= other.end }
    func overlaps(_ other: Self) -> Bool { start <= other.end && other.start <= end }
}

enum PeriodPrecision: String, Codable {
    case month, year, range
    func validate(_ period: LedgerPeriod) throws {
        switch self {
        case .range: return
        case .month:
            guard period == .month(containing: period.start.date()) else {
                throw LedgerError.invalid("按月汇总必须覆盖一个完整自然月。")
            }
        case .year:
            guard period == .year(containing: period.start.date()) else {
                throw LedgerError.invalid("按年汇总必须覆盖一个完整自然年。")
            }
        }
    }
}

struct EntryDraft {
    var kind: EntryKind = .expense
    var amount = ""
    var day = LedgerDay(date: Date()).rawValue
    var categoryID: String?
    var accountID: String?
    var destinationAccountID: String?
    var originalEntryID: String?
    var note = ""
    var refundReference = ""
    var refundReason = ""
}

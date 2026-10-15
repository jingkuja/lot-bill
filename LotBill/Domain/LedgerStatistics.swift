import Foundation

struct LedgerTotals {
    var income: Int64 = 0
    var consumption: Int64 = 0
    var refunds: Int64 = 0
    var adjustment: Int64 = 0
    var netExpense: Int64 = 0
    var surplus: Int64 = 0
    var byCategory: [String: Int64] = [:]
    var byFirstCategory: [String: Int64] = [:]
    var unsplitPeriods: [String] = []
    var entryCount = 0
}

@MainActor enum LedgerStatistics {
    /// Categories have two levels, so a first-level history summary also covers every child category.
    nonisolated static func categoriesOverlap(_ a: String?, _ b: String?, parents: [String: String]) -> Bool {
        guard let a, let b else { return false }
        return a == b || parents[a] == b || parents[b] == a
    }
    static func calculate(period: LedgerPeriod, entries: [LedgerEntry], histories: [HistoricalSummary] = [], adjustments: [MonthlyAdjustment] = [], parents: [String: String] = [:]) throws -> LedgerTotals {
        var total = LedgerTotals()
        let activeHistory = histories.filter(\.isActive)
        for (index, history) in activeHistory.enumerated() {
            let range = try LedgerPeriod(start: history.startDay, end: history.endDay)
            guard let precision = PeriodPrecision(rawValue: history.precision) else { throw LedgerError.invalid("未知的历史期间精度。") }
            try precision.validate(range)
            guard history.amountCents >= 0, history.amountCents <= Money.maximum, history.currency == "CNY",
                  history.kindRaw == EntryKind.expense.rawValue || history.kindRaw == EntryKind.income.rawValue else {
                throw LedgerError.invalid("历史汇总的金额、币种或收支类型无效。")
            }
            guard range.overlaps(period) else { continue }
            if entries.contains(where: { categoriesOverlap($0.categoryID, history.categoryID, parents: parents) && $0.currency == history.currency && $0.kind != .transfer && range.contains($0.day) }) {
                throw LedgerError.invalid("历史汇总与明细存在重叠，请先解决冲突。")
            }
            for other in activeHistory.dropFirst(index + 1) where categoriesOverlap(other.categoryID, history.categoryID, parents: parents) && other.currency == history.currency {
                if range.overlaps(try LedgerPeriod(start: other.startDay, end: other.endDay)) {
                    throw LedgerError.invalid("历史期间相互重叠，无法安全计算。")
                }
            }
            if !period.contains(range) {
                total.unsplitPeriods.append("\(history.startDay) 至 \(history.endDay)")
                continue
            }
            if history.kindRaw == EntryKind.income.rawValue {
                total.income = try Money.add(total.income, history.amountCents)
            } else {
                total.consumption = try Money.add(total.consumption, history.amountCents)
                total.byCategory[history.categoryID] = try Money.add(total.byCategory[history.categoryID, default: 0], history.amountCents)
            }
        }
        for entry in entries where period.contains(entry.day) {
            guard entry.currency == "CNY", entry.amountCents > 0, entry.amountCents <= Money.maximum,
                  EntryKind(rawValue: entry.kindRaw) != nil else { throw LedgerError.invalid("流水包含无效金额、币种或类型。") }
            total.entryCount += 1
            switch entry.kind {
            case .income: total.income = try Money.add(total.income, entry.amountCents)
            case .expense:
                total.consumption = try Money.add(total.consumption, entry.amountCents)
                total.byCategory[entry.categoryID ?? ""] = try Money.add(total.byCategory[entry.categoryID ?? "", default: 0], entry.amountCents)
            case .refund:
                total.refunds = try Money.add(total.refunds, entry.amountCents)
                total.byCategory[entry.categoryID ?? ""] = try Money.add(total.byCategory[entry.categoryID ?? "", default: 0], -entry.amountCents)
            case .transfer: break
            }
        }
        var adjustmentSources: Set<String> = []
        for adjustment in adjustments where adjustment.isActive {
            let start = try LedgerDay(adjustment.month + "-01")
            let month = LedgerPeriod.month(containing: start.date())
            guard month.overlaps(period) else { continue }
            guard adjustment.currency == "CNY", period.contains(month),
                  (-Money.maximum...Money.maximum).contains(adjustment.signedCents),
                  adjustmentSources.insert(adjustment.statementItemID).inserted else { throw LedgerError.invalid("月度调整存在范围、金额或重复来源问题。") }
            total.adjustment = try Money.add(total.adjustment, adjustment.signedCents)
            total.byCategory[adjustment.categoryID] = try Money.add(total.byCategory[adjustment.categoryID, default: 0], adjustment.signedCents)
        }
        total.netExpense = try Money.add(try Money.subtract(total.consumption, total.refunds), total.adjustment)
        total.surplus = try Money.subtract(total.income, total.netExpense)
        for (id, amount) in total.byCategory {
            let parent = parents[id] ?? id
            total.byFirstCategory[parent] = try Money.add(total.byFirstCategory[parent, default: 0], amount)
        }
        total.unsplitPeriods = Array(Set(total.unsplitPeriods)).sorted()
        return total
    }
}

import Foundation

struct ReconciliationDifference: Identifiable {
    let item: ReconciliationItem
    let recorded: Int64
    let adjustment: Int64
    let external: Int64?
    let difference: Int64?
    let suggestedAdjustment: Int64?
    let issue: String?
    var id: String { item.id }
}

extension LedgerRepository {
    func insertStatement(month: String, values: [String: Int64], basis: String, batchID: String?) throws -> ReconciliationStatement {
        _ = try LedgerDay(month + "-01")
        guard !values.isEmpty, ["netExpense", "grossExpense"].contains(basis) else { throw LedgerError.invalid("请提供至少一个分类金额并确认退款口径。") }
        let available = selectableCategories(for: .expense)
        for (id, value) in values {
            guard available.contains(where: { $0.id == id }), (-Money.maximum...Money.maximum).contains(value), basis == "netExpense" || value >= 0 else { throw LedgerError.invalid("对账分类或金额无效。") }
        }
        let old = statements.filter { $0.month == month }
        for statement in old where statement.isActive {
            statement.isActive = false; statement.isReviewed = false
            let ids = Set(statementItems.filter { $0.statementID == statement.id }.map(\.id))
            for adjustment in adjustments where adjustment.isActive && ids.contains(adjustment.statementItemID) { adjustment.isActive = false }
        }
        let statement = ReconciliationStatement(month: month)
        statement.version = (old.map(\.version).max() ?? 0) + 1
        statement.basis = basis; statement.batchID = batchID
        context.insert(statement)
        for category in available {
            context.insert(ReconciliationItem(statementID: statement.id, categoryID: category.id, amountCents: values[category.id]))
        }
        context.insert(LedgerAudit(ownerID: statement.id, kind: "statement", payload: "建立版本 \(statement.version)；全部账户；CNY；\(basis)。替代版本的调整已停用，请重新核对。"))
        return statement
    }
    @discardableResult func saveStatement(month: String, values: [String: Int64], basis: String = "netExpense") throws -> String {
        if statements.contains(where: { statement in
            guard statement.month == month && statement.isActive && statement.basis == basis else { return false }
            let items = statementItems.filter { $0.statementID == statement.id && $0.amountCents != nil }
            return items.count == values.count && items.allSatisfy { values[$0.categoryID] == $0.amountCents }
        }) { throw LedgerError.invalid("同月相同金额的依据已存在，无需重复保存。") }
        var id = ""
        try commit { id = try insertStatement(month: month, values: values, basis: basis, batchID: nil).id }
        return id
    }
    func differences(for statement: ReconciliationStatement) throws -> [ReconciliationDifference] {
        let period = LedgerPeriod.month(containing: try LedgerDay(statement.month + "-01").date())
        let parents = categoryParents
        return try statementItems.filter { $0.statementID == statement.id }.sorted { categoryPath($0.categoryID) < categoryPath($1.categoryID) }.map { item in
            let total = try LedgerStatistics.calculate(period: period, entries: entries.filter { $0.categoryID == item.categoryID }, histories: histories.filter { $0.categoryID == item.categoryID }, adjustments: adjustments.filter { $0.categoryID == item.categoryID })
            let recorded = statement.basis == "grossExpense" ? total.consumption : try Money.subtract(total.consumption, total.refunds)
            let adjustment = statement.basis == "grossExpense" ? 0 : total.adjustment
            let own = try adjustments.filter { $0.isActive && $0.statementItemID == item.id }.reduce(Int64(0)) { try Money.add($0, $1.signedCents) }
            let parentHistory = try histories.contains { h in
                guard h.isActive, parents[item.categoryID] == h.categoryID else { return false }
                return try LedgerPeriod(start: h.startDay, end: h.endDay).overlaps(period)
            }
            let parentRefund = statement.basis == "netExpense" && entries.contains {
                $0.kind == .refund && $0.categoryID == parents[item.categoryID] && period.contains($0.day)
            }
            let issue = parentRefund ? "该月有按大类记录的历史消费退款，不能分摊至子类生成差额。" : parentHistory ? "该月历史按大类汇总，不能按子类生成差额。" : !total.unsplitPeriods.isEmpty ? "历史期间未按月拆分，不能生成月度差额。" : nil
            let difference = try item.amountCents.map { try Money.subtract($0, Money.add(recorded, adjustment)) }
            let suggested = try item.amountCents.map { try Money.subtract($0, Money.subtract(Money.add(recorded, adjustment), own)) }
            return ReconciliationDifference(item: item, recorded: recorded, adjustment: adjustment, external: item.amountCents,
                                            difference: issue == nil ? difference : nil,
                                            suggestedAdjustment: issue == nil && statement.basis == "netExpense" ? suggested : nil, issue: issue)
        }
    }
    func reviseAdjustment(itemID: String, expectedCents: Int64, reason: String) throws {
        guard let item = statementItems.first(where: { $0.id == itemID }),
              let statement = statements.first(where: { $0.id == item.statementID && $0.isActive }),
              statement.basis == "netExpense" else { throw LedgerError.invalid("只可调整当前有效的净支出对账依据。") }
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 1000 else { throw LedgerError.invalid("请填写 1–1000 字的调整原因。") }
        let revisions = adjustments.filter { $0.statementItemID == itemID }
        guard let row = try differences(for: statement).first(where: { $0.id == itemID }) else { throw LedgerError.invalid("对账项不存在。") }
        let clearingBlocked = row.issue != nil && expectedCents == 0 && revisions.contains { $0.isActive && $0.signedCents != 0 }
        guard let suggested = clearingBlocked ? 0 : row.suggestedAdjustment,
              suggested == expectedCents, (-Money.maximum...Money.maximum).contains(suggested) else { throw LedgerError.invalid("差额已变化或不可计算，请刷新后重新确认。") }
        if let active = revisions.first(where: \.isActive), active.signedCents == suggested { throw LedgerError.invalid("当前调整已经是该金额，无需重复执行。") }
        if revisions.isEmpty && suggested == 0 { throw LedgerError.invalid("差额为零，无需调整。") }
        try commit {
            for old in revisions where old.isActive { old.isActive = false }
            let adjustment = MonthlyAdjustment(month: statement.month, categoryID: item.categoryID, signedCents: suggested, reason: clean, statementItemID: itemID)
            adjustment.revision = (revisions.map(\.revision).max() ?? 0) + 1
            context.insert(adjustment)
            try invalidateStatements(months: [statement.month])
            context.insert(LedgerAudit(ownerID: statement.id, kind: "adjustment", payload: "\(categoryPath(item.categoryID))：调整修订 v\(adjustment.revision) = \(Money.display(suggested))；\(clean)"))
        }
    }
    func reviewStatement(_ statement: ReconciliationStatement, unresolvedReason: String = "") throws {
        guard statements.contains(where: { $0.id == statement.id && $0.isActive }) else { throw LedgerError.invalid("仅可核对当前有效版本。") }
        let rows = try differences(for: statement)
        let supplied = rows.filter { $0.external != nil }
        guard !supplied.isEmpty else { throw LedgerError.invalid("没有提供可核对的分类金额。") }
        let unresolved = supplied.contains { $0.issue != nil || $0.difference != 0 }
        let reason = unresolvedReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unresolved || !reason.isEmpty else { throw LedgerError.invalid("仍有差异或未拆分历史；请填写保留差异的原因。") }
        guard reason.count <= 1000 else { throw LedgerError.invalid("说明最多 1000 字。") }
        let snapshot = rows.map { "\(categoryPath($0.item.categoryID))：外部 \($0.external.map(Money.decimal) ?? "未提供")；账本 \(Money.decimal($0.recorded))；调整 \(Money.decimal($0.adjustment))；差额 \($0.difference.map(Money.decimal) ?? "不可计算")" }.joined(separator: "\n")
        try commit {
            statement.isReviewed = true
            context.insert(LedgerAudit(ownerID: statement.id, kind: "review", payload: (unresolved ? "已核对，保留差异：\(reason)" : "已提供分类的差额为零。") + "\n" + snapshot))
        }
    }
}

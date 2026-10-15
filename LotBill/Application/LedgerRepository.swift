import Foundation
import SwiftData
import Observation

@MainActor protocol LedgerWriting {
    func save(_ draft: EntryDraft, editingID: String?) throws
    func delete(_ entry: LedgerEntry) throws
}

@MainActor @Observable final class LedgerRepository: LedgerWriting {
    let preferences: LedgerPreferences
    let context: ModelContext
    private(set) var entries: [LedgerEntry] = []
    private(set) var categories: [LedgerCategory] = []
    private(set) var accounts: [LedgerAccount] = []
    private(set) var histories: [HistoricalSummary] = []
    private(set) var adjustments: [MonthlyAdjustment] = []
    private(set) var batches: [ImportBatch] = []
    private(set) var statements: [ReconciliationStatement] = []
    private(set) var statementItems: [ReconciliationItem] = []
    private(set) var audits: [LedgerAudit] = []
    private(set) var revision = 0
    var restoreGeneration = 0
    var restoreNotice: String?

    init(container: ModelContainer, preferences: LedgerPreferences? = nil) throws {
        let config = container.configurations.first
        self.preferences = preferences ?? LedgerPreferences(scope: config?.isStoredInMemoryOnly == true ? UUID().uuidString : (config?.url.path ?? LedgerStore.scope))
        context = ModelContext(container)
        context.autosaveEnabled = false
        try seedCategories()
        try reload()
    }

    func reload() throws {
        entries = try context.fetch(FetchDescriptor<LedgerEntry>()).sorted {
            $0.day == $1.day ? $0.createdAt > $1.createdAt : $0.day > $1.day
        }
        categories = try context.fetch(FetchDescriptor<LedgerCategory>()).sorted {
            $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder
        }
        accounts = try context.fetch(FetchDescriptor<LedgerAccount>()).sorted { $0.sortOrder < $1.sortOrder }
        histories = try context.fetch(FetchDescriptor<HistoricalSummary>())
        adjustments = try context.fetch(FetchDescriptor<MonthlyAdjustment>())
        batches = try context.fetch(FetchDescriptor<ImportBatch>()).sorted { $0.createdAt > $1.createdAt }
        statements = try context.fetch(FetchDescriptor<ReconciliationStatement>()).sorted { $0.month == $1.month ? $0.version > $1.version : $0.month > $1.month }
        statementItems = try context.fetch(FetchDescriptor<ReconciliationItem>())
        audits = try context.fetch(FetchDescriptor<LedgerAudit>()).sorted { $0.createdAt > $1.createdAt }
        revision += 1
    }

    func commit(_ change: () throws -> Void) throws {
        do {
            try change()
            try context.save()
        } catch {
            context.rollback()
            try? reload()
            throw error
        }
        try reload()
    }

    private func seedCategories() throws {
        let existing = Set(try context.fetch(FetchDescriptor<LedgerCategory>()).map(\.id))
        for seed in CategorySeeds.all where !existing.contains(seed.id) { context.insert(seed) }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func categoryName(_ id: String?) -> String {
        guard let category = categories.first(where: { $0.id == id }) else { return "未分类" }
        return category.name
    }
    func categoryPath(_ id: String?) -> String {
        guard let category = categories.first(where: { $0.id == id }) else { return "未分类" }
        guard let parent = categories.first(where: { $0.id == category.parentID }) else { return category.name }
        return "\(parent.name) · \(category.name)"
    }
    var categoryParents: [String: String] {
        Dictionary(uniqueKeysWithValues: categories.compactMap { c in c.parentID.map { (c.id, $0) } })
    }
    /// Historical files can contain either first-level totals or second-level totals.
    func historyCategories(for kind: EntryKind) -> [LedgerCategory] {
        categories.filter { category in category.kindRaw == kind.rawValue && !category.isArchived &&
            !categories.contains(where: { $0.id == category.parentID && $0.isArchived }) }
    }
    func accountName(_ id: String?) -> String { accounts.first(where: { $0.id == id })?.name ?? "未指定账户" }
    func selectableCategories(for kind: EntryKind) -> [LedgerCategory] {
        let parentIDs = Set(categories.compactMap(\.parentID))
        let archivedIDs = Set(categories.lazy.filter(\.isArchived).map(\.id))
        return categories.filter { category in
            category.kindRaw == kind.rawValue && !category.isArchived &&
            !parentIDs.contains(category.id) &&
            !archivedIDs.contains(category.parentID ?? "")
        }
    }
    func draft(for entry: LedgerEntry) -> EntryDraft {
        let evidence = historicalRefundEvidence(for: entry)
        return EntryDraft(kind: entry.kind, amount: Money.decimal(entry.amountCents), day: entry.day,
                   categoryID: entry.categoryID, accountID: entry.accountID, destinationAccountID: entry.destinationAccountID,
                   originalEntryID: entry.originalEntryID, note: entry.note, refundReference: evidence?.reference ?? "", refundReason: evidence?.reason ?? "")
    }

    func save(_ draft: EntryDraft, editingID: String? = nil) throws {
        let amount = try Money.parse(draft.amount)
        let day = try LedgerDay(draft.day)
        let old = entries.first { $0.id == editingID }
        guard editingID == nil || old != nil else { throw LedgerError.invalid("记录已不存在，请刷新后重试。") }
        guard draft.note.count <= 1000 else { throw LedgerError.invalid("备注最多 1000 字。") }
        var categoryID = draft.categoryID
        var accountID = draft.accountID
        var destinationID: String?
        var originalID: String?

        func validateAccount(_ id: String?, previous: String?, required: Bool = false) throws {
            guard let id else {
                if required { throw LedgerError.invalid("请选择转出和转入账户。") }
                return
            }
            guard let account = accounts.first(where: { $0.id == id }), !account.isArchived || previous == id else {
                throw LedgerError.invalid("账户不存在或已停用。")
            }
        }
        if draft.kind == .refund {
            guard let sourceID = draft.originalEntryID else { throw LedgerError.invalid("请选择原支出或历史汇总。") }
            let refunded = try entries.filter { $0.originalEntryID == sourceID && $0.id != editingID }
                .reduce(Int64(0)) { try Money.add($0, $1.amountCents) }
            if let original = entries.first(where: { $0.id == sourceID && $0.kind == .expense }) {
                guard day.rawValue >= original.day else { throw LedgerError.invalid("退款日期不能早于原支出。") }
                guard try Money.add(refunded, amount) <= original.amountCents else { throw LedgerError.invalid("累计退款不能超过原支出金额。") }
                categoryID = original.categoryID; accountID = original.accountID
            } else if let history = refundableHistories.first(where: { $0.id == sourceID }) {
                guard day.rawValue > history.endDay else { throw LedgerError.invalid("历史消费退款须发生在历史覆盖截止日之后。") }
                guard try Money.add(refunded, amount) <= history.amountCents else { throw LedgerError.invalid("此历史汇总的累计退款不能超过原汇总金额。") }
                try HistoricalRefundEvidence(entryID: editingID ?? "new", historyID: sourceID, amountCents: amount, day: day.rawValue, reference: draft.refundReference, reason: draft.refundReason).validate()
                categoryID = history.categoryID
                try validateAccount(accountID, previous: old?.accountID)
            } else { throw LedgerError.invalid("退款来源不存在、已撤销或不支持。") }
            originalID = sourceID
        } else {
            try validateAccount(accountID, previous: old?.accountID, required: draft.kind == .transfer)
            if draft.kind == .transfer {
                try validateAccount(draft.destinationAccountID, previous: old?.destinationAccountID, required: true)
                guard accountID != draft.destinationAccountID else { throw LedgerError.invalid("转出和转入不能是同一个账户。") }
                categoryID = nil; destinationID = draft.destinationAccountID
            } else {
                guard let category = categories.first(where: { $0.id == categoryID }),
                      category.kindRaw == draft.kind.rawValue,
                      !categories.contains(where: { $0.parentID == category.id }),
                      selectableCategories(for: draft.kind).contains(where: { $0.id == category.id }) || old?.categoryID == category.id else {
                    throw LedgerError.invalid("请选择有效的收支分类。")
                }
            }
        }
        if let old {
            let refunds = entries.filter { $0.originalEntryID == old.id }
            if !refunds.isEmpty {
                let total = try refunds.reduce(Int64(0)) { try Money.add($0, $1.amountCents) }
                guard draft.kind == .expense, categoryID == old.categoryID, accountID == old.accountID,
                      amount >= total, refunds.allSatisfy({ $0.day >= day.rawValue }) else {
                    throw LedgerError.invalid("此支出已有退款。请先处理关联退款，再更改类型、分类、账户或缩减到已退款金额以下。")
                }
            }
        }
        if draft.kind != .transfer {
            let parents = categoryParents
            for history in histories where history.isActive && LedgerStatistics.categoriesOverlap(history.categoryID, categoryID, parents: parents) && history.currency == "CNY" {
                let period = try LedgerPeriod(start: history.startDay, end: history.endDay)
                if period.contains(day.rawValue) {
                    throw LedgerError.invalid("该分类日期已被历史汇总覆盖，请先解决重叠，避免重复统计。")
                }
            }
        }
        let affectedMonths = Set([old.map { String($0.day.prefix(7)) }, day.month].compactMap { $0 })
        try commit {
            let entry = old ?? LedgerEntry(kind: draft.kind, amountCents: amount, day: day.rawValue)
            if old == nil { context.insert(entry) }
            entry.kindRaw = draft.kind.rawValue; entry.amountCents = amount; entry.day = day.rawValue
            entry.categoryID = categoryID; entry.accountID = accountID; entry.destinationAccountID = destinationID
            entry.originalEntryID = originalID; entry.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.updatedAt = Date()
            if let originalID, histories.contains(where: { $0.id == originalID }) {
                let evidence = HistoricalRefundEvidence(entryID: entry.id, historyID: originalID, amountCents: amount, day: day.rawValue,
                    reference: draft.refundReference.trimmingCharacters(in: .whitespacesAndNewlines), reason: draft.refundReason.trimmingCharacters(in: .whitespacesAndNewlines))
                context.insert(LedgerAudit(ownerID: originalID, kind: "historicalRefund", payload: String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)))
            }
            try invalidateStatements(months: affectedMonths)
        }
    }

    func delete(_ entry: LedgerEntry) throws {
        guard !entries.contains(where: { $0.originalEntryID == entry.id }) else {
            throw LedgerError.invalid("这笔支出有关联退款，请先删除或修正退款记录。")
        }
        try commit {
            try invalidateStatements(months: [String(entry.day.prefix(7))])
            context.delete(entry)
        }
    }
    func invalidateStatements(months: Set<String>) throws {
        for statement in try context.fetch(FetchDescriptor<ReconciliationStatement>()) where months.contains(statement.month) {
            statement.isReviewed = false
        }
    }

    func saveAccount(id: String? = nil, name: String, archived: Bool = false) throws {
        let clean = try validName(name)
        guard id == nil || accounts.contains(where: { $0.id == id }) else { throw LedgerError.invalid("账户已不存在。") }
        guard !accounts.contains(where: { $0.id != id && $0.name == clean }) else { throw LedgerError.invalid("账户名称已存在。") }
        try commit {
            let account = accounts.first { $0.id == id } ?? LedgerAccount(name: clean, sortOrder: accounts.count)
            if id == nil { context.insert(account) }
            account.name = clean; account.isArchived = archived
        }
    }
    func saveCategory(id: String? = nil, name: String, parentID: String?, kind: EntryKind, archived: Bool = false) throws {
        let clean = try validName(name)
        guard id == nil || categories.contains(where: { $0.id == id }) else { throw LedgerError.invalid("分类已不存在。") }
        guard kind == .expense || kind == .income else { throw LedgerError.invalid("分类仅适用于收入和支出。") }
        if let parentID {
            guard let parent = categories.first(where: { $0.id == parentID }), parent.parentID == nil,
                  parent.kindRaw == kind.rawValue, !parent.isArchived else { throw LedgerError.invalid("请选择有效的大类。") }
            if id == nil && (entries.contains { $0.categoryID == parentID } || statementItems.contains { $0.categoryID == parentID } || adjustments.contains { $0.categoryID == parentID }) {
                throw LedgerError.invalid("该分类已直接用于记账，不能再作为新子类的大类。请另建大类。")
            }
        }
        guard !categories.contains(where: { $0.id != id && $0.name == clean && $0.parentID == parentID && $0.kindRaw == kind.rawValue }) else {
            throw LedgerError.invalid("同级分类名称已存在。")
        }
        if let existing = categories.first(where: { $0.id == id }) {
            guard existing.parentID == parentID, existing.kindRaw == kind.rawValue else { throw LedgerError.invalid("已有分类的层级与收支类型不能修改。") }
        }
        try commit {
            let category = categories.first { $0.id == id } ?? LedgerCategory(name: clean, parentID: parentID, kind: kind, sortOrder: categories.count)
            if id == nil { context.insert(category) }
            category.name = clean; category.isArchived = archived
        }
    }
    private func validName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40 else { throw LedgerError.invalid("名称需要 1–40 个字。") }
        return clean
    }
}

@MainActor enum CategorySeeds {
    static var all: [LedgerCategory] {
        let groups: [(String, String, [String])] = [
            ("daily", "日常支出", ["理发", "工作餐", "餐饮", "超市", "网上购置", "手机充值", "公共出行", "高铁打车", "差旅租房", "考试培训", "医社交税"]),
            ("clothing", "服饰", ["衣服", "鞋帽", "背包", "其他"]),
            ("entertainment", "娱乐", ["游戏软件", "会员充值", "出游"]),
            ("digital", "数码产品", ["配件", "apple", "手机配件"]),
            ("car", "用车费用", ["油费", "保养", "保险", "洗车", "停车", "路费"])
        ]
        var result: [LedgerCategory] = []
        for (index, group) in groups.enumerated() {
            let parentID = "expense.\(group.0)"
            result.append(LedgerCategory(id: parentID, name: group.1, kind: .expense, sortOrder: index * 100))
            for (childIndex, name) in group.2.enumerated() {
                result.append(LedgerCategory(id: "\(parentID).\(childIndex)", name: name, parentID: parentID, kind: .expense, sortOrder: index * 100 + childIndex + 1))
            }
        }
        result.append(LedgerCategory(id: "income.other", name: "其他收入", kind: .income, sortOrder: 1000))
        return result
    }
}

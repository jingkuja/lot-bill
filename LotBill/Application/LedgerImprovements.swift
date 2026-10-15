import Foundation
import SwiftData
import Observation
import CryptoKit

struct QuickEntryTemplate: Codable, Identifiable {
    var id = UUID().uuidString
    let name: String
    let kind: EntryKind
    let amount: String
    let categoryID: String
    let accountID: String?
    let note: String
}
struct BackupStamp: Codable {
    let exportedAt: Date
    let snapshotAt: Date
    let fingerprints: [String: String]
}
struct BackupDelta: Equatable {
    var added = 0
    var changed = 0
    var removed = 0
    var total: Int { added + changed + removed }
}
@MainActor @Observable final class LedgerPreferences {
    private let defaults: UserDefaults
    private let key: String
    var templates: [QuickEntryTemplate] { didSet { defaults.set(try? JSONEncoder().encode(templates), forKey: key + ".templates") } }
    var recentAccountID: String? { didSet { defaults.set(recentAccountID, forKey: key + ".account") } }
    var recentCategories: [String] { didSet { defaults.set(recentCategories, forKey: key + ".categories") } }
    var backupStamp: BackupStamp? { didSet { defaults.set(try? JSONEncoder().encode(backupStamp), forKey: key + ".backup") } }
    var reminderDays: Int { didSet { defaults.set(reminderDays, forKey: key + ".reminder") } }
    var rehearsedAt: Date? { didSet { defaults.set(rehearsedAt, forKey: key + ".rehearsal") } }
    init(scope: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "ledger.preferences." + scope
        templates = defaults.data(forKey: key + ".templates").flatMap { try? JSONDecoder().decode([QuickEntryTemplate].self, from: $0) } ?? []
        recentAccountID = defaults.string(forKey: key + ".account")
        recentCategories = defaults.stringArray(forKey: key + ".categories") ?? []
        backupStamp = defaults.data(forKey: key + ".backup").flatMap { try? JSONDecoder().decode(BackupStamp.self, from: $0) }
        reminderDays = defaults.object(forKey: key + ".reminder") as? Int ?? 7
        rehearsedAt = defaults.object(forKey: key + ".rehearsal") as? Date
    }
    func backupDue(now: Date = Date()) -> Bool {
        guard reminderDays > 0 else { return false }
        guard let stamp = backupStamp else { return true }
        return now.timeIntervalSince(stamp.exportedAt) >= Double(reminderDays) * 86400
    }
    func recordExport(_ snapshot: LedgerBackup, at date: Date = Date()) throws {
        backupStamp = BackupStamp(exportedAt: date, snapshotAt: snapshot.createdAt, fingerprints: try snapshot.fingerprints())
    }
    func changes(in snapshot: LedgerBackup) throws -> BackupDelta? {
        guard let stamp = backupStamp else { return nil }
        let current = try snapshot.fingerprints()
        return BackupDelta(added: current.keys.filter { stamp.fingerprints[$0] == nil }.count,
                           changed: current.keys.filter { stamp.fingerprints[$0] != nil && stamp.fingerprints[$0] != current[$0] }.count,
                           removed: stamp.fingerprints.keys.filter { current[$0] == nil }.count)
    }
}
extension LedgerBackup {
    func fingerprints() throws -> [String: String] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var result: [String: String] = [:]
        func add<T: Encodable>(_ items: [T], id: (T) -> String) throws {
            for item in items { result[id(item)] = SHA256.hash(data: try encoder.encode(item)).map { String(format: "%02x", $0) }.joined() }
        }
        try add(accounts, id: { $0.id }); try add(categories, id: { $0.id }); try add(entries, id: { $0.id })
        try add(histories, id: { $0.id }); try add(batches, id: { $0.id }); try add(statements, id: { $0.id })
        try add(statementItems, id: { $0.id }); try add(adjustments, id: { $0.id }); try add(audits, id: { $0.id })
        return result
    }
}
struct HistoricalRefundEvidence: Codable, Equatable {
    let entryID: String
    let historyID: String
    let amountCents: Int64
    let day: String
    let reference: String
    let reason: String
    func validate() throws {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reference.count <= 200,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 1000,
              !entryID.isEmpty, !historyID.isEmpty, (1...Money.maximum).contains(amountCents) else {
            throw LedgerError.invalid("历史退款需填写凭据说明（1–200 字）和原因（1–1000 字）。")
        }
        _ = try LedgerDay(day)
    }
}
struct CategoryCoverage: Identifiable {
    let id: String
    let name: String
    let history: String?
    let supplied: Int
    let expected: Int
    let reviewed: Bool
    let hasEntries: Bool
    var status: String {
        if let history { return history }
        if supplied == 0 { return "未提供依据" }
        return "\(reviewed ? "已核对" : "待核对") · \(supplied)/\(expected) 个分类"
    }
}
extension LedgerRepository {
    func historicalRefundEvidence(for entry: LedgerEntry) -> HistoricalRefundEvidence? {
        audits.lazy.filter { $0.kind == "historicalRefund" && $0.ownerID == entry.originalEntryID }.compactMap {
            try? JSONDecoder().decode(HistoricalRefundEvidence.self, from: Data($0.payload.utf8))
        }.first { $0.entryID == entry.id && $0.amountCents == entry.amountCents && $0.day == entry.day }
    }
    var refundableHistories: [HistoricalSummary] {
        histories.filter { $0.isActive && $0.kindRaw == "expense" && $0.batchID != nil && $0.amountCents > 0 }
            .sorted { $0.endDay == $1.endDay ? $0.categoryID < $1.categoryID : $0.endDay > $1.endDay }
    }
    func quickDraft(kind: EntryKind = .expense) -> EntryDraft {
        let available = selectableCategories(for: kind)
        let recent = preferences.recentCategories.first { id in available.contains { $0.id == id } }
        let account = accounts.first { $0.id == preferences.recentAccountID && !$0.isArchived }?.id
        return EntryDraft(kind: kind, categoryID: recent ?? available.first(where: { $0.name == "餐饮" })?.id ?? available.first?.id, accountID: account)
    }
    func saveTemplate(_ draft: EntryDraft) throws {
        _ = try Money.parse(draft.amount)
        guard draft.kind == .expense || draft.kind == .income,
              let id = draft.categoryID, selectableCategories(for: draft.kind).contains(where: { $0.id == id }), draft.note.count <= 1000 else { throw LedgerError.invalid("模板需有有效的收入或支出分类。") }
        guard preferences.templates.count < 20 else { throw LedgerError.invalid("最多保存 20 个模板，请先删除不用的模板。") }
        let template = QuickEntryTemplate(name: categoryName(id) + " · ¥" + draft.amount, kind: draft.kind, amount: draft.amount, categoryID: id, accountID: draft.accountID, note: draft.note)
        preferences.templates.append(template)
    }
    func draft(from template: QuickEntryTemplate) -> EntryDraft {
        EntryDraft(kind: template.kind, amount: template.amount,
                   categoryID: selectableCategories(for: template.kind).first { $0.id == template.categoryID }?.id,
                   accountID: accounts.first { $0.id == template.accountID && !$0.isArchived }?.id, note: template.note)
    }
    func remember(_ draft: EntryDraft) {
        preferences.recentAccountID = draft.accountID
        if let id = draft.categoryID, draft.kind == .expense || draft.kind == .income {
            preferences.recentCategories = [id] + preferences.recentCategories.filter { $0 != id }.prefix(5)
        }
    }
    func reorderCategories(_ orderedIDs: [String], parentID: String?, kind: EntryKind) throws {
        let siblings = categories.filter { $0.parentID == parentID && $0.kindRaw == kind.rawValue }
        guard Set(orderedIDs) == Set(siblings.map(\.id)), orderedIDs.count == siblings.count else { throw LedgerError.invalid("分类列表已变化，请刷新后排序。") }
        try commit {
            for (index, id) in orderedIDs.enumerated() { siblings.first { $0.id == id }?.sortOrder = index }
        }
    }
    func coverage(month: String) throws -> [CategoryCoverage] {
        let period = LedgerPeriod.month(containing: try LedgerDay(month + "-01").date())
        let statement = statements.first { $0.month == month && $0.isActive }
        let suppliedIDs = Set(statementItems.filter { $0.statementID == statement?.id && $0.amountCents != nil }.map(\.categoryID))
        return try categories.filter { $0.parentID == nil && $0.kindRaw == "expense" }.map { parent in
            let children = categories.filter { $0.parentID == parent.id }
            let ids = Set([parent.id] + children.map(\.id))
            let relevant = try histories.filter {
                guard $0.isActive && ids.contains($0.categoryID) else { return false }
                return try LedgerPeriod(start: $0.startDay, end: $0.endDay).overlaps(period)
            }
            let unsplit = try relevant.contains { !period.contains(try LedgerPeriod(start: $0.startDay, end: $0.endDay)) }
            let history = relevant.isEmpty ? nil : (unsplit ? "历史未按月拆分" : "含历史汇总")
            let expected = Set(selectableCategories(for: .expense).filter { ids.contains($0.id) }.map(\.id)).union(suppliedIDs.intersection(ids)).count
            return CategoryCoverage(id: parent.id, name: parent.name, history: history,
                                    supplied: suppliedIDs.intersection(ids).count, expected: expected,
                                    reviewed: statement?.isReviewed == true, hasEntries: entries.contains { ids.contains($0.categoryID ?? "") && period.contains($0.day) })
        }
    }
    func rehearseRestore(_ backup: LedgerBackup) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LotBill-Rehearsal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let isolated = try LedgerRepository(container: LedgerStore.container(inMemory: true))
        try isolated.restore(backup, expectedRevision: isolated.revision, directory: folder)
        var restored = try isolated.backup(); restored.createdAt = backup.createdAt; restored.version = backup.version
        guard try restored.encoded() == backup.encoded() else { throw LedgerError.invalid("恢复演练后的数据不一致。") }
        preferences.rehearsedAt = Date()
    }
}

// Shared by the iPhone list and Mac table so filtering uses the same rules.
extension LedgerRepository {
    func filteredEntries(period: LedgerPeriod, kind: String, category: String, account: String, search: String) -> [LedgerEntry] {
        let parents = categoryParents
        return entries.filter { entry in
            period.contains(entry.day) && (kind == "all" || entry.kindRaw == kind) &&
            (category == "all" || entry.categoryID == category || parents[entry.categoryID ?? ""] == category) &&
            (account == "all" || entry.accountID == account || entry.destinationAccountID == account) &&
            (search.isEmpty || "\(entry.note) \(categoryPath(entry.categoryID)) \(accountName(entry.accountID)) \(accountName(entry.destinationAccountID)) \(Money.decimal(entry.amountCents))".localizedCaseInsensitiveContains(search))
        }
    }
}

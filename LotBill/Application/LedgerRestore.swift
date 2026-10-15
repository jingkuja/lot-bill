import Foundation
import SwiftData

extension LedgerRepository {
    func backup() throws -> LedgerBackup {
        let result = LedgerBackup(repository: self)
        try result.validate()
        return result
    }
    static func recoveryDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("RecoveryPoints").appendingPathComponent(LedgerStore.scope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    // A synchronous main-actor transaction prevents app writes interleaving with replacement.
    // The validated recovery file is durably saved BEFORE the first model mutation.
    @discardableResult func restore(_ incoming: LedgerBackup, expectedRevision: Int, directory: URL? = nil, beforeSave: (() throws -> Void)? = nil) throws -> URL {
        guard revision == expectedRevision else { throw LedgerError.invalid("账本在预览后发生变化，请重新预览恢复影响。") }
        try incoming.validate()
        let recoveryData = try backup().encoded()
        let folder = try directory ?? Self.recoveryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let recoveryURL = folder.appendingPathComponent("BeforeRestore-\(timestamp)-\(UUID().uuidString).json")
        try recoveryData.write(to: recoveryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        // Keep the recovery point even if the database transaction later fails.
        try commit {
            let oldAccount = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            for dto in incoming.accounts {
                let value = oldAccount[dto.id] ?? LedgerAccount(id: dto.id, name: dto.name)
                if oldAccount[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.name = dto.name
                value.isArchived = dto.isArchived
                value.sortOrder = dto.sortOrder
            }
            let newAccountIDs = Set(incoming.accounts.map(\.id))
            for old in accounts where !newAccountIDs.contains(old.id) { context.delete(old) }
            let oldCategory = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            for dto in incoming.categories {
                let value = oldCategory[dto.id] ?? LedgerCategory(id: dto.id, name: dto.name, kind: .expense)
                if oldCategory[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.name = dto.name
                value.parentID = dto.parentID
                value.kindRaw = dto.kindRaw
                value.sortOrder = dto.sortOrder
                value.isArchived = dto.isArchived
            }
            let newCategoryIDs = Set(incoming.categories.map(\.id))
            for old in categories where !newCategoryIDs.contains(old.id) { context.delete(old) }
            let oldEntry = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            for dto in incoming.entries {
                let value = oldEntry[dto.id] ?? LedgerEntry(id: dto.id, kind: .expense, amountCents: dto.amountCents, day: dto.day)
                if oldEntry[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.kindRaw = dto.kindRaw
                value.amountCents = dto.amountCents
                value.day = dto.day
                value.timeZoneID = dto.timeZoneID
                value.currency = dto.currency
                value.categoryID = dto.categoryID
                value.accountID = dto.accountID
                value.destinationAccountID = dto.destinationAccountID
                value.originalEntryID = dto.originalEntryID
                value.note = dto.note
                value.createdAt = dto.createdAt
                value.updatedAt = dto.updatedAt
            }
            let newEntryIDs = Set(incoming.entries.map(\.id))
            for old in entries where !newEntryIDs.contains(old.id) { context.delete(old) }
            let oldHistory = Dictionary(uniqueKeysWithValues: histories.map { ($0.id, $0) })
            for dto in incoming.histories {
                let value = oldHistory[dto.id] ?? HistoricalSummary(startDay: dto.startDay, endDay: dto.endDay, precision: dto.precision, categoryID: dto.categoryID, kind: .expense, amountCents: dto.amountCents)
                if oldHistory[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.startDay = dto.startDay
                value.endDay = dto.endDay
                value.precision = dto.precision
                value.categoryID = dto.categoryID
                value.kindRaw = dto.kindRaw
                value.currency = dto.currency
                value.amountCents = dto.amountCents
                value.batchID = dto.batchID
                value.isActive = dto.isActive
            }
            let newHistoryIDs = Set(incoming.histories.map(\.id))
            for old in histories where !newHistoryIDs.contains(old.id) { context.delete(old) }
            let oldBatch = Dictionary(uniqueKeysWithValues: batches.map { ($0.id, $0) })
            for dto in incoming.batches {
                let value = oldBatch[dto.id] ?? ImportBatch(purpose: dto.purpose, digest: dto.digest, sourceName: dto.sourceName)
                if oldBatch[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.purpose = dto.purpose
                value.digest = dto.digest
                value.mappingVersion = dto.mappingVersion
                value.sourceName = dto.sourceName
                value.status = dto.status
                value.createdAt = dto.createdAt
            }
            let newBatchIDs = Set(incoming.batches.map(\.id))
            for old in batches where !newBatchIDs.contains(old.id) { context.delete(old) }
            let oldStatement = Dictionary(uniqueKeysWithValues: statements.map { ($0.id, $0) })
            for dto in incoming.statements {
                let value = oldStatement[dto.id] ?? ReconciliationStatement(month: dto.month)
                if oldStatement[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.month = dto.month
                value.scope = dto.scope
                value.basis = dto.basis
                value.version = dto.version
                value.isActive = dto.isActive
                value.isReviewed = dto.isReviewed
                value.batchID = dto.batchID
            }
            let newStatementIDs = Set(incoming.statements.map(\.id))
            for old in statements where !newStatementIDs.contains(old.id) { context.delete(old) }
            let oldItem = Dictionary(uniqueKeysWithValues: statementItems.map { ($0.id, $0) })
            for dto in incoming.statementItems {
                let value = oldItem[dto.id] ?? ReconciliationItem(statementID: dto.statementID, categoryID: dto.categoryID, amountCents: dto.amountCents)
                if oldItem[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.statementID = dto.statementID
                value.categoryID = dto.categoryID
                value.amountCents = dto.amountCents
                value.currency = dto.currency
            }
            let newItemIDs = Set(incoming.statementItems.map(\.id))
            for old in statementItems where !newItemIDs.contains(old.id) { context.delete(old) }
            let oldAdjustment = Dictionary(uniqueKeysWithValues: adjustments.map { ($0.id, $0) })
            for dto in incoming.adjustments {
                let value = oldAdjustment[dto.id] ?? MonthlyAdjustment(month: dto.month, categoryID: dto.categoryID, signedCents: dto.signedCents, reason: dto.reason, statementItemID: dto.statementItemID)
                if oldAdjustment[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.month = dto.month
                value.categoryID = dto.categoryID
                value.signedCents = dto.signedCents
                value.reason = dto.reason
                value.statementItemID = dto.statementItemID
                value.revision = dto.revision
                value.isActive = dto.isActive
                value.currency = dto.currency
            }
            let newAdjustmentIDs = Set(incoming.adjustments.map(\.id))
            for old in adjustments where !newAdjustmentIDs.contains(old.id) { context.delete(old) }
            let oldAudit = Dictionary(uniqueKeysWithValues: audits.map { ($0.id, $0) })
            for dto in incoming.audits {
                let value = oldAudit[dto.id] ?? LedgerAudit(ownerID: dto.ownerID, kind: dto.kind, payload: dto.payload)
                if oldAudit[dto.id] == nil { context.insert(value) }
                value.id = dto.id
                value.ownerID = dto.ownerID
                value.kind = dto.kind
                value.payload = dto.payload
                value.createdAt = dto.createdAt
            }
            let newAuditIDs = Set(incoming.audits.map(\.id))
            for old in audits where !newAuditIDs.contains(old.id) { context.delete(old) }
            try beforeSave?()
            #if DEBUG
            M7Acceptance.interruptRestore(at: "before-save")
            #endif
        }
        #if DEBUG
        M7Acceptance.interruptRestore(at: "after-save")
        #endif
        restoreNotice = "账本恢复成功，原账本已保存为本机恢复点。"
        restoreGeneration += 1
        return recoveryURL
    }
}

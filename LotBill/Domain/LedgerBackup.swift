import Foundation

// Stable logical format, independent of SwiftData archive representation. No service keys or consent.
struct LedgerBackup: Codable, Sendable {
    var format = "lotbill-ledger"
    var version = 1
    var createdAt = Date()
    var accounts: [Account]
    var categories: [Category]
    var entries: [Entry]
    var histories: [History]
    var batches: [Batch]
    var statements: [Statement]
    var statementItems: [Item]
    var adjustments: [Adjustment]
    var audits: [Audit]
    @MainActor init(repository: LedgerRepository) {
        accounts = repository.accounts.map(Account.init).sorted { $0.id < $1.id }
        categories = repository.categories.map(Category.init).sorted { $0.id < $1.id }
        entries = repository.entries.map(Entry.init).sorted { $0.id < $1.id }
        histories = repository.histories.map(History.init).sorted { $0.id < $1.id }
        batches = repository.batches.map(Batch.init).sorted { $0.id < $1.id }
        statements = repository.statements.map(Statement.init).sorted { $0.id < $1.id }
        statementItems = repository.statementItems.map(Item.init).sorted { $0.id < $1.id }
        adjustments = repository.adjustments.map(Adjustment.init).sorted { $0.id < $1.id }
        audits = repository.audits.map(Audit.init).sorted { $0.id < $1.id }
        version = audits.contains { $0.kind == "historicalRefund" } ? 2 : 1
    }
    struct Account: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var isArchived: Bool
        var sortOrder: Int
        @MainActor init(_ value: LedgerAccount) {
            id = value.id
            name = value.name
            isArchived = value.isArchived
            sortOrder = value.sortOrder
        }
    }
    struct Category: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var parentID: String?
        var kindRaw: String
        var sortOrder: Int
        var isArchived: Bool
        @MainActor init(_ value: LedgerCategory) {
            id = value.id
            name = value.name
            parentID = value.parentID
            kindRaw = value.kindRaw
            sortOrder = value.sortOrder
            isArchived = value.isArchived
        }
    }
    struct Entry: Codable, Sendable, Equatable {
        var id: String
        var kindRaw: String
        var amountCents: Int64
        var day: String
        var timeZoneID: String
        var currency: String
        var categoryID: String?
        var accountID: String?
        var destinationAccountID: String?
        var originalEntryID: String?
        var note: String
        var createdAt: Date
        var updatedAt: Date
        @MainActor init(_ value: LedgerEntry) {
            id = value.id
            kindRaw = value.kindRaw
            amountCents = value.amountCents
            day = value.day
            timeZoneID = value.timeZoneID
            currency = value.currency
            categoryID = value.categoryID
            accountID = value.accountID
            destinationAccountID = value.destinationAccountID
            originalEntryID = value.originalEntryID
            note = value.note
            createdAt = value.createdAt
            updatedAt = value.updatedAt
        }
    }
    struct History: Codable, Sendable, Equatable {
        var id: String
        var startDay: String
        var endDay: String
        var precision: String
        var categoryID: String
        var kindRaw: String
        var currency: String
        var amountCents: Int64
        var batchID: String?
        var isActive: Bool
        @MainActor init(_ value: HistoricalSummary) {
            id = value.id
            startDay = value.startDay
            endDay = value.endDay
            precision = value.precision
            categoryID = value.categoryID
            kindRaw = value.kindRaw
            currency = value.currency
            amountCents = value.amountCents
            batchID = value.batchID
            isActive = value.isActive
        }
    }
    struct Batch: Codable, Sendable, Equatable {
        var id: String
        var purpose: String
        var digest: String
        var mappingVersion: Int
        var sourceName: String
        var status: String
        var createdAt: Date
        @MainActor init(_ value: ImportBatch) {
            id = value.id
            purpose = value.purpose
            digest = value.digest
            mappingVersion = value.mappingVersion
            sourceName = value.sourceName
            status = value.status
            createdAt = value.createdAt
        }
    }
    struct Statement: Codable, Sendable, Equatable {
        var id: String
        var month: String
        var scope: String
        var basis: String
        var version: Int
        var isActive: Bool
        var isReviewed: Bool
        var batchID: String?
        @MainActor init(_ value: ReconciliationStatement) {
            id = value.id
            month = value.month
            scope = value.scope
            basis = value.basis
            version = value.version
            isActive = value.isActive
            isReviewed = value.isReviewed
            batchID = value.batchID
        }
    }
    struct Item: Codable, Sendable, Equatable {
        var id: String
        var statementID: String
        var categoryID: String
        var amountCents: Int64?
        var currency: String
        @MainActor init(_ value: ReconciliationItem) {
            id = value.id
            statementID = value.statementID
            categoryID = value.categoryID
            amountCents = value.amountCents
            currency = value.currency
        }
    }
    struct Adjustment: Codable, Sendable, Equatable {
        var id: String
        var month: String
        var categoryID: String
        var signedCents: Int64
        var reason: String
        var statementItemID: String
        var revision: Int
        var isActive: Bool
        var currency: String
        @MainActor init(_ value: MonthlyAdjustment) {
            id = value.id
            month = value.month
            categoryID = value.categoryID
            signedCents = value.signedCents
            reason = value.reason
            statementItemID = value.statementItemID
            revision = value.revision
            isActive = value.isActive
            currency = value.currency
        }
    }
    struct Audit: Codable, Sendable, Equatable {
        var id: String
        var ownerID: String
        var kind: String
        var payload: String
        var createdAt: Date
        @MainActor init(_ value: LedgerAudit) {
            id = value.id
            ownerID = value.ownerID
            kind = value.kind
            payload = value.payload
            createdAt = value.createdAt
        }
    }
}

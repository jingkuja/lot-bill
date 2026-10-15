import Foundation
import SwiftData

enum LedgerSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Account.self, Category.self, Entry.self, History.self, ImportBatch.self, Statement.self, StatementItem.self, Adjustment.self]
    }

    @Model final class Account {
        @Attribute(.unique) var id: String
        var name: String
        var isArchived: Bool
        var sortOrder: Int
        init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0) {
            self.id = id; self.name = name; self.sortOrder = sortOrder; isArchived = false
        }
    }
    @Model final class Category {
        @Attribute(.unique) var id: String
        var name: String
        var parentID: String?
        var kindRaw: String
        var sortOrder: Int
        var isArchived: Bool
        init(id: String = UUID().uuidString, name: String, parentID: String? = nil, kind: EntryKind, sortOrder: Int = 0) {
            self.id = id; self.name = name; self.parentID = parentID
            self.kindRaw = kind.rawValue; self.sortOrder = sortOrder; isArchived = false
        }
    }
    @Model final class Entry {
        @Attribute(.unique) var id: String
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
        init(id: String = UUID().uuidString, kind: EntryKind, amountCents: Int64, day: String,
             categoryID: String? = nil, accountID: String? = nil, destinationAccountID: String? = nil,
             originalEntryID: String? = nil, note: String = "") {
            self.id = id; kindRaw = kind.rawValue; self.amountCents = amountCents; self.day = day
            timeZoneID = TimeZone.current.identifier; currency = "CNY"; self.categoryID = categoryID
            self.accountID = accountID; self.destinationAccountID = destinationAccountID
            self.originalEntryID = originalEntryID; self.note = note; createdAt = Date(); updatedAt = Date()
        }
        var kind: EntryKind { EntryKind(rawValue: kindRaw) ?? .expense }
    }
    @Model final class History {
        @Attribute(.unique) var id: String
        var startDay: String
        var endDay: String
        var precision: String
        var categoryID: String
        var kindRaw: String
        var currency: String
        var amountCents: Int64
        var batchID: String?
        var isActive: Bool
        init(startDay: String, endDay: String, precision: String, categoryID: String, kind: EntryKind, amountCents: Int64) {
            id = UUID().uuidString; self.startDay = startDay; self.endDay = endDay; self.precision = precision
            self.categoryID = categoryID; kindRaw = kind.rawValue; currency = "CNY"; self.amountCents = amountCents; isActive = true
        }
    }
    @Model final class ImportBatch {
        @Attribute(.unique) var id: String
        var purpose: String
        var digest: String
        var mappingVersion: Int
        var sourceName: String
        var status: String
        var createdAt: Date
        init(purpose: String, digest: String, sourceName: String) {
            id = UUID().uuidString; self.purpose = purpose; self.digest = digest; self.sourceName = sourceName
            mappingVersion = 1; status = "preview"; createdAt = Date()
        }
    }
    @Model final class Statement {
        @Attribute(.unique) var id: String
        var month: String
        var scope: String
        var basis: String
        var version: Int
        var isActive: Bool
        var isReviewed: Bool
        var batchID: String?
        init(month: String) {
            id = UUID().uuidString; self.month = month; scope = "allAccounts"; basis = "netExpense"
            version = 1; isActive = true; isReviewed = false
        }
    }
    @Model final class StatementItem {
        @Attribute(.unique) var id: String
        var statementID: String
        var categoryID: String
        var amountCents: Int64?
        var currency: String
        init(statementID: String, categoryID: String, amountCents: Int64?) {
            id = UUID().uuidString; self.statementID = statementID; self.categoryID = categoryID
            self.amountCents = amountCents; currency = "CNY"
        }
    }
    @Model final class Adjustment {
        @Attribute(.unique) var id: String
        var month: String
        var categoryID: String
        var signedCents: Int64
        var reason: String
        var statementItemID: String
        var revision: Int
        var isActive: Bool
        var currency: String
        init(month: String, categoryID: String, signedCents: Int64, reason: String, statementItemID: String) {
            id = UUID().uuidString; self.month = month; self.categoryID = categoryID; self.signedCents = signedCents
            self.reason = reason; self.statementItemID = statementItemID; revision = 1; isActive = true; currency = "CNY"
        }
    }
}

typealias LedgerAccount = LedgerSchemaV1.Account
typealias LedgerCategory = LedgerSchemaV1.Category
typealias LedgerEntry = LedgerSchemaV1.Entry
typealias HistoricalSummary = LedgerSchemaV1.History
typealias ImportBatch = LedgerSchemaV1.ImportBatch
typealias ReconciliationStatement = LedgerSchemaV1.Statement
typealias ReconciliationItem = LedgerSchemaV1.StatementItem
typealias MonthlyAdjustment = LedgerSchemaV1.Adjustment

enum LedgerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { LedgerSchemaV1.models + [Audit.self] }
    @Model final class Audit {
        @Attribute(.unique) var id: String
        var ownerID: String
        var kind: String
        var payload: String
        var createdAt: Date
        init(ownerID: String, kind: String, payload: String) {
            id = UUID().uuidString; self.ownerID = ownerID; self.kind = kind
            self.payload = payload; createdAt = Date()
        }
    }
}
typealias LedgerAudit = LedgerSchemaV2.Audit

enum LedgerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LedgerSchemaV1.self, LedgerSchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: LedgerSchemaV1.self, toVersion: LedgerSchemaV2.self)] }
}

enum LedgerStore {
    nonisolated static var scope: String {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--ledger-test-store"), args.indices.contains(index + 1), UUID(uuidString: args[index + 1]) != nil { return args[index + 1] }
        #endif
        return "main"
    }
    @MainActor static func container(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LedgerSchemaV2.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            var base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            #if os(macOS)
            base = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.lotlife.lotbill.mac", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            #endif
            var name = "Ledger-v1.store"
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--ledger-test-store"), args.indices.contains(index + 1),
               UUID(uuidString: args[index + 1]) != nil {
                name = "LedgerUITest-\(args[index + 1]).store"
            }
            #endif
            configuration = ModelConfiguration(schema: schema, url: url ?? base.appendingPathComponent(name), cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: LedgerMigrationPlan.self, configurations: [configuration])
    }
}

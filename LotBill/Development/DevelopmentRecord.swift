import Foundation
import SwiftData

// P0 verification data. Kept separate from the future production ledger schema.
@Model
final class DevelopmentRecord {
    var id: UUID
    var text: String
    var createdAt: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
    }
}

enum DevelopmentStore {
    @MainActor
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([DevelopmentRecord.self])
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var storeName = "DevelopmentCheck.store"
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            storeName = "DevelopmentUITest.store"
        }
#endif
        let configuration = ModelConfiguration(
            "DevelopmentCheck",
            schema: schema,
            url: base.appendingPathComponent(storeName),
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}


import SwiftUI
import SwiftData

@main
struct LotBillApp: App {
    private let repository: Result<LedgerRepository, Error>
    init() {
        repository = Result {
            let repository = try LedgerRepository(container: LedgerStore.container())
            #if DEBUG
            try M7Acceptance.prepare(repository)
            #endif
            return repository
        }
    }
    #if os(macOS)
    @State private var navigation = MacLedgerNavigation()
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Lot Bill", id: "ledger") {
            content
        }
        .defaultSize(width: 1180, height: 760)
        .commands { MacLedgerCommands(navigation: navigation) }
        Settings {
            if case .success(let repository) = repository {
                LedgerSettingsView(repository: repository)
                    .id(repository.restoreGeneration)
                    .formStyle(.grouped)
                    .frame(width: 650, height: 620)
            }
        }
        #else
        WindowGroup { content }
        #endif
    }

    @ViewBuilder private var content: some View {
        switch repository {
        case .success(let repository):
            #if os(macOS)
            MacLedgerRootView(repository: repository, navigation: navigation)
                .background(.background)
            #else
            LedgerRootView(repository: repository)
                #if DEBUG
                .modifier(M7Appearance())
                #endif
            #endif
        case .failure:
            ContentUnavailableView("本地账本暂不可用", systemImage: "externaldrive.badge.exclamationmark",
                description: Text("初始化没有完成，请重新启动 App。现有记录不会被自动清除。"))
        }
    }
}

#if DEBUG
private struct M7Appearance: ViewModifier {
    func body(content: Content) -> some View {
        if LedgerStore.scope != "main", ProcessInfo.processInfo.arguments.contains("--m7-accessibility") {
            content.environment(\.dynamicTypeSize, .accessibility5).preferredColorScheme(.dark)
        } else { content }
    }
}
// Acceptance data is opt-in and can never run against the user's normal ledger.
@MainActor enum M7Acceptance {
    static func prepare(_ repository: LedgerRepository) throws {
        guard LedgerStore.scope != "main" else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--m7-restore-fixture"), !FileManager.default.fileExists(atPath: try restoreFixtureURL().path) {
            try repository.backup().encoded().write(to: restoreFixtureURL(), options: .atomic)
        }
        if arguments.contains("--m7-files") {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("M7-" + LedgerStore.scope)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("大类,分类,金额\n日常支出,餐饮,1200\n日常支出,超市,0".utf8)
                .write(to: folder.appendingPathComponent("M7-History.csv"), options: .atomic)
        }
        if arguments.contains("--m7-large"), repository.entries.isEmpty {
            let month = LedgerDay(date: Date()).month
            try repository.commit {
                for index in 0..<10_000 {
                    let entry = LedgerEntry(id: "m7-scale-\(index)", kind: .expense, amountCents: 101,
                        day: String(format: "%@-%02d", month, index % 28 + 1))
                    entry.categoryID = "expense.daily.2"; entry.note = "Synthetic scale \(index)"
                    repository.context.insert(entry)
                }
            }
        }
    }
    static func restoreFixtureURL() throws -> URL {
        try LedgerRepository.recoveryDirectory().appendingPathComponent("M7-incoming.json")
    }
    static func interruptRestore(at point: String) {
        guard LedgerStore.scope != "main",
              ProcessInfo.processInfo.arguments.contains("--m7-exit-" + point) else { return }
        // No lifecycle callbacks or context save: deterministic abrupt process termination.
        _exit(0)
    }
}
#endif

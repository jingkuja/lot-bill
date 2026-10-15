#if os(macOS)
import SwiftUI
import Observation

@MainActor @Observable final class MacLedgerNavigation {
    var section: MacLedgerSection? = .overview
    var showEntry = false
    var searchRequest = 0
}

enum MacLedgerSection: String, CaseIterable, Identifiable {
    case overview = "概览", entries = "流水", reports = "统计", history = "历史导入"
    case reconciliation = "月度对账", ai = "AI 辅助", data = "数据管理"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .entries: "list.bullet.rectangle"
        case .reports: "chart.bar.xaxis"
        case .history: "square.and.arrow.down"
        case .reconciliation: "checkmark.circle"
        case .ai: "sparkles"
        case .data: "slider.horizontal.3"
        }
    }
}

struct MacLedgerRootView: View {
    let repository: LedgerRepository
    @Bindable var navigation: MacLedgerNavigation

    var body: some View {
        NavigationSplitView {
            List(MacLedgerSection.allCases, selection: $navigation.section) { section in
                Label {
                    Text(section.rawValue)
                        .font(.headline.weight(navigation.section == section ? .semibold : .regular))
                } icon: {
                    Image(systemName: section.symbol)
                        .foregroundStyle(navigation.section == section ? Color.teal : Color.secondary)
                }
                .tag(section)
                .accessibilityIdentifier("mac.sidebar." + String(describing: section))
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .navigationTitle("Lot Bill")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本机账本")
                            .font(.caption.weight(.medium))
                        Text("离线安全存储")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
        } detail: {
            Group {
                switch navigation.section ?? .overview {
                case .overview: OverviewView(repository: repository)
                case .entries: MacEntriesView(repository: repository, navigation: navigation)
                case .reports: ReportsView(repository: repository)
                case .history: NavigationStack { HistoryImportView(repository: repository, purpose: .history) }
                case .reconciliation: NavigationStack { ReconciliationListView(repository: repository) }
                case .ai: NavigationStack { AIAssistanceView(repository: repository) }
                case .data: LedgerSettingsView(repository: repository)
                }
            }
            .id(repository.restoreGeneration)
            .formStyle(.grouped)
        }
        .tint(.teal)
        .frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $navigation.showEntry) { EntryEditor(repository: repository) }
        .onChange(of: repository.restoreGeneration) { _, _ in navigation.showEntry = false }
    }
}

struct MacLedgerCommands: Commands {
    @Bindable var navigation: MacLedgerNavigation
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("记一笔") { navigation.showEntry = true }
                .keyboardShortcut("n")
                .disabled(navigation.showEntry)
        }
        CommandGroup(after: .textEditing) {
            Button("搜索流水") {
                navigation.section = .entries
                navigation.searchRequest += 1
            }.keyboardShortcut("f")
        }
        SidebarCommands()
    }
}

private struct MacEntryRow: Identifiable {
    let id: String
    let day: String
    let kind: EntryKind
    let category: String
    let account: String
    let amount: Int64
    let note: String
}

private struct MacEntriesView: View {
    let repository: LedgerRepository
    let navigation: MacLedgerNavigation
    @State private var month = Date()
    @State private var search = ""
    @State private var kind = "all"
    @State private var category = "all"
    @State private var account = "all"
    @State private var selectedID: String?
    @State private var showDetail = false
    @State private var sortOrder = [KeyPathComparator(\MacEntryRow.day, order: .reverse)]
    @FocusState private var searchFocused: Bool

    private var matches: [LedgerEntry] {
        repository.filteredEntries(period: .month(containing: month), kind: kind, category: category, account: account, search: search)
    }
    private var rows: [MacEntryRow] {
        matches.map { entry in
            MacEntryRow(id: entry.id, day: entry.day, kind: entry.kind,
                category: entry.kind == .transfer ? "账户转账" : repository.categoryPath(entry.categoryID),
                account: entry.kind == .transfer
                    ? repository.accountName(entry.accountID) + " → " + repository.accountName(entry.destinationAccountID)
                    : repository.accountName(entry.accountID),
                amount: entry.amountCents, note: entry.note)
        }.sorted(using: sortOrder)
    }
    private var selectedEntry: LedgerEntry? { repository.entries.first { $0.id == selectedID } }
    private var adjustments: [MonthlyAdjustment] {
        guard account == "all", kind == "all" || kind == "expense", search.isEmpty else { return [] }
        return repository.adjustments.filter {
            $0.isActive && $0.month == LedgerDay(date: month).month &&
            (category == "all" || $0.categoryID == category || repository.categoryParents[$0.categoryID] == category)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 24) {
                    MonthSelector(date: $month).frame(width: 250)
                    Spacer()
                    TextField("搜索备注、分类、账户、金额", text: $search)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                        .focused($searchFocused).accessibilityIdentifier("mac.entries.search")
                }
                HStack {
                    Picker("类型", selection: $kind) {
                        Text("全部").tag("all")
                        ForEach(EntryKind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("分类", selection: $category) {
                        Text("全部").tag("all")
                        ForEach(repository.categories) { Text(repository.categoryPath($0.id)).tag($0.id) }
                    }
                    Picker("账户", selection: $account) {
                        Text("全部").tag("all")
                        ForEach(repository.accounts) { Text($0.name).tag($0.id) }
                    }
                }
            }.padding()
            Divider()
            Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
                TableColumn("日期", value: \.day).width(min: 90, ideal: 100)
                TableColumn("类型") { row in
                    Text(row.kind.title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(row.kind.themeColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(row.kind.themeColor)
                }.width(60)
                TableColumn("分类", value: \.category)
                TableColumn("账户", value: \.account)
                TableColumn("金额", value: \.amount) { row in
                    let prefix = row.kind == .income ? "+" : (row.kind == .expense ? "-" : "")
                    Text(prefix + Money.display(row.amount))
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(row.kind == .income ? Color.teal : (row.kind == .expense ? Color.primary : Color.secondary))
                }
                .width(min: 100, ideal: 130)
                TableColumn("备注", value: \.note)
            }
            .accessibilityIdentifier("mac.entries.table")
            .contextMenu(forSelectionType: String.self) { ids in
                Button("查看记录") { selectedID = ids.first; showDetail = true }.disabled(ids.isEmpty)
            } primaryAction: { ids in
                selectedID = ids.first; showDetail = true
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("还没有匹配的流水", systemImage: "list.bullet.rectangle", description: Text("调整月份或筛选条件，也可以记一笔。"))
                }
            }
            if !adjustments.isEmpty {
                DisclosureGroup("月度调整 · \(adjustments.count) 项（不属于每日交易）") {
                    ScrollView {
                        ForEach(adjustments) { adjustment in
                            LabeledContent(repository.categoryPath(adjustment.categoryID), value: Money.display(adjustment.signedCents))
                            Text("修订 \(adjustment.revision) · \(adjustment.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxHeight: 120)
                }.padding()
            }
            HStack {
                Text("\(rows.count) 笔流水").accessibilityIdentifier("mac.entries.count")
                Spacer()
                Text("双击记录查看详情，点击列标题排序")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .navigationTitle("流水")
        .toolbar {
            Button("查看记录") { showDetail = true }.disabled(selectedEntry == nil)
            Button { navigation.showEntry = true } label: { Label("记一笔", systemImage: "plus") }
                .accessibilityIdentifier("entries.add")
        }
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                if let selectedEntry {
                    EntryDetailView(repository: repository, entry: selectedEntry)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showDetail = false }.keyboardShortcut(.cancelAction) } }
                }
            }.ledgerEditorSize()
        }
        .onAppear { if navigation.searchRequest > 0 { searchFocused = true } }
        .onChange(of: navigation.searchRequest) { _, _ in searchFocused = true }
        .onChange(of: matches.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil; showDetail = false }
        }
    }
}
#endif

import SwiftUI

struct LedgerSettingsView: View {
    let repository: LedgerRepository
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("账本保存在本机", systemImage: "internaldrive")
                    Text("无需登录记账账户，也无需联网即可维护每日记录。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("账本管理") {
                    NavigationLink { AccountsView(repository: repository) } label: { Label("账户", systemImage: "creditcard") }
                    NavigationLink { CategoriesView(repository: repository) } label: { Label("分类", systemImage: "square.grid.2x2") }
                }
                Section("导入与对账") {
                    NavigationLink("历史文件导入") { HistoryImportView(repository: repository, purpose: .history) }
                    NavigationLink("导入批次与覆盖") { ImportBatchesView(repository: repository) }
                    NavigationLink("月度对账") { ReconciliationListView(repository: repository) }
                }
                Section("AI 与数据管理") {
                    NavigationLink("AI 服务配置") { AIConfigurationView() }
                    NavigationLink("AI 辅助记账与月报") { AIAssistanceView(repository: repository) }
                    NavigationLink("CSV 导出") { CSVExportView(repository: repository) }
                    NavigationLink("备份与恢复") { BackupRestoreView(repository: repository) }
                }
                Section("统计口径") {
                    Text("收支结余按已录入数据计算，不代表银行卡或支付账户余额。转账不计入收支，退款冲减原分类的支出。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("开发进度") {
                    Text("首版 M7 试用验收已完成。已补充年度大类统计、导入核验、备份提醒、快捷记账、覆盖视图和历史退款。真实账单、真实 AI 服务及最低系统版本仍待验证。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("设置")
        }
    }
}

private struct AccountsView: View {
    let repository: LedgerRepository
    @State private var showNew = false
    var body: some View {
        List {
            if repository.accounts.isEmpty {
                ContentUnavailableView("建立你的第一个账户", systemImage: "creditcard", description: Text("例如现金或工资卡。账户只用于归属和筛选，不会连接银行。"))
            }
            ForEach(repository.accounts) { account in
                NavigationLink {
                    AccountEditor(repository: repository, account: account)
                } label: {
                    HStack { Text(account.name); Spacer(); if account.isArchived { Text("已停用").foregroundStyle(.secondary) } }
                }
            }
        }.navigationTitle("账户")
            .toolbar { Button { showNew = true } label: { Label("添加账户", systemImage: "plus") }.accessibilityIdentifier("account.add") }
            .sheet(isPresented: $showNew) { NavigationStack { AccountEditor(repository: repository) }.ledgerEditorSize() }
    }
}

private struct AccountEditor: View {
    let repository: LedgerRepository
    let account: LedgerAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var archived: Bool
    @State private var error: String?
    init(repository: LedgerRepository, account: LedgerAccount? = nil) {
        self.repository = repository; self.account = account
        _name = State(initialValue: account?.name ?? ""); _archived = State(initialValue: account?.isArchived ?? false)
    }
    var body: some View {
        Form {
            TextField("账户名称", text: $name).accessibilityIdentifier("account.name")
            if account != nil {
                Toggle("停用账户", isOn: $archived)
                Text("停用后保留历史记录，新记账时不再提供此账户。").font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            Button("保存") {
                do { try repository.saveAccount(id: account?.id, name: name, archived: archived); dismiss() }
                catch { self.error = error.localizedDescription }
            }.accessibilityIdentifier("account.save")
        }.ledgerForm().navigationTitle(account == nil ? "添加账户" : "编辑账户")
            .toolbar { if account == nil { Button("取消") { dismiss() } } }
    }
}

private struct CategoriesView: View {
    let repository: LedgerRepository
    @State private var showNew = false
    var body: some View {
        List {
            Section { NavigationLink("调整分类顺序") { CategoryOrderView(repository: repository) } }
            ForEach(repository.categories.filter { $0.parentID == nil }) { parent in
                Section(parent.kindRaw == "income" ? "收入" : parent.name) {
                    NavigationLink { CategoryEditor(repository: repository, category: parent) } label: {
                        HStack { Text(parent.name); Spacer(); Text(parent.isArchived ? "已停用" : "分类设置").foregroundStyle(.secondary).font(.caption) }
                    }
                    ForEach(repository.categories.filter { $0.parentID == parent.id }) { category in
                        NavigationLink { CategoryEditor(repository: repository, category: category) } label: {
                            HStack { Text(category.name); Spacer(); if category.isArchived { Text("已停用").font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                }
            }
        }.navigationTitle("分类")
            .toolbar { Button { showNew = true } label: { Label("添加分类", systemImage: "plus") } }
            .sheet(isPresented: $showNew) { NavigationStack { CategoryEditor(repository: repository) }.ledgerEditorSize() }
    }
}

private struct CategoryEditor: View {
    let repository: LedgerRepository
    let category: LedgerCategory?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: EntryKind
    @State private var parentID: String?
    @State private var archived: Bool
    @State private var error: String?
    init(repository: LedgerRepository, category: LedgerCategory? = nil) {
        self.repository = repository; self.category = category
        _name = State(initialValue: category?.name ?? "")
        _kind = State(initialValue: EntryKind(rawValue: category?.kindRaw ?? "expense") ?? .expense)
        _parentID = State(initialValue: category?.parentID)
        _archived = State(initialValue: category?.isArchived ?? false)
    }
    var body: some View {
        Form {
            TextField("分类名称", text: $name)
            if category == nil {
                Picker("类型", selection: $kind) { Text("支出").tag(EntryKind.expense); Text("收入").tag(EntryKind.income) }
                Picker("所属大类", selection: $parentID) {
                    Text("无（新增大类）").tag(String?.none)
                    ForEach(repository.categories.filter { $0.parentID == nil && $0.kindRaw == kind.rawValue && !$0.isArchived }) { c in
                        Text(c.name).tag(Optional(c.id))
                    }
                }
            } else {
                Toggle("停用分类", isOn: $archived)
                Text("修改名称不会改变历史记录的归属；停用大类后，其子类也不再用于新记账。").font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            Button("保存") {
                do { try repository.saveCategory(id: category?.id, name: name, parentID: parentID, kind: kind, archived: archived); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }.ledgerForm().navigationTitle(category == nil ? "添加分类" : "编辑分类")
            .toolbar { if category == nil { Button("取消") { dismiss() } } }
            .onChange(of: kind) { _, _ in parentID = nil }
    }
}

private struct CategoryOrderView: View {
    let repository: LedgerRepository
    @State private var kind: EntryKind = .expense
    @State private var parentID: String?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Picker("类型", selection: $kind) { Text("支出").tag(EntryKind.expense); Text("收入").tag(EntryKind.income) }
                Picker("排序范围", selection: $parentID) {
                    Text("第一分类").tag(String?.none)
                    ForEach(repository.categories.filter { $0.parentID == nil && $0.kindRaw == kind.rawValue }) { parent in Text(parent.name).tag(Optional(parent.id)) }
                }
                #if os(macOS)
                Text("使用上下箭头调整同级分类顺序。").font(.caption)
                #else
                Text("点击编辑后拖动同级分类；历史归属保持不变。").font(.caption)
                #endif
            }
            Section {
                let siblings = repository.categories.filter { $0.parentID == parentID && $0.kindRaw == kind.rawValue }
                ForEach(Array(siblings.enumerated()), id: \.element.id) { index, category in
                    HStack {
                        Text(category.name)
                        #if os(macOS)
                        Spacer()
                        Button { move(siblings, from: index, to: index - 1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).accessibilityLabel("上移" + category.name)
                        Button { move(siblings, from: index, to: index + 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == siblings.count - 1).accessibilityLabel("下移" + category.name)
                        #endif
                    }
                }
                    .onMove { source, destination in
                        var ids = siblings.map(\.id); ids.move(fromOffsets: source, toOffset: destination)
                        do { try repository.reorderCategories(ids, parentID: parentID, kind: kind) }
                        catch { self.error = error.localizedDescription }
                    }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("分类排序").toolbar {
                #if os(iOS)
                EditButton()
                #endif
            }
            .onChange(of: kind) { _, _ in parentID = nil }
    }
    private func move(_ siblings: [LedgerCategory], from source: Int, to destination: Int) {
        guard siblings.indices.contains(destination) else { return }
        var ids = siblings.map(\.id)
        ids.swapAt(source, destination)
        do { try repository.reorderCategories(ids, parentID: parentID, kind: kind) }
        catch { self.error = error.localizedDescription }
    }

}

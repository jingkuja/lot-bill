import SwiftUI
import UniformTypeIdentifiers

struct HistoryImportView: View {
    let repository: LedgerRepository
    let purpose: ImportPurpose
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picking = false
    @State private var file: ImportFile?
    @State private var mapping = ImportMapping()
    @State private var yearText = String(ImportMapping().year)
    @State private var preview: ImportPreview?
    @State private var loading = false
    @State private var error: String?
    @State private var success: String?
    @State private var confirm = false
    @State private var month = Date()
    var body: some View {
        Form {
            Section(purpose == .history ? "1 · 选择年度文件" : "选择月度文件") {
                Button { picking = true } label: { Label("选择 XLSX / CSV 文件", systemImage: "doc.badge.plus") }.disabled(loading)
                if loading { ProgressView("正在读取文件…") }
                if let file { Text(file.name).font(.caption) }
                Text(purpose == .history
                     ? "历史文件按第一、第二分类保存年度支出汇总。2026 年数据截至 8 月 31 日，不拆分到各月；只有大类金额时保存大类汇总。人民币、全部账户。空白不等于零，总计仅用于校验。原文件不复制保存。"
                     : "只导入自整理分类汇总；人民币、全部账户。空白不等于零，总计仅用于校验。原文件不复制保存。").font(.footnote).foregroundStyle(.secondary)
            }
            if purpose == .history {
                Section { NavigationLink("查看与编辑历史账单") { ImportBatchesView(repository: repository) }.accessibilityIdentifier("history.list") }
            }
            if let file {
                mappingSection(file)
                Section {
                    Button("生成预览") {
                        do { preview = try repository.preview(file: file, mapping: mapping, purpose: purpose); error = nil; success = nil }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("import.preview")
                }
                if let preview { if purpose == .history { historyPreviewSection(preview) } else { previewSection(preview) } }
            }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("import.error") } }
            if let success { Section { Text(success).foregroundStyle(.teal) } }
        }.scrollDismissesKeyboard(.interactively)
            .navigationTitle(purpose == .history ? "历史文件导入" : "月度文件导入")
            .task {
                #if DEBUG
                // UI tests supply only synthetic CSV, and only inside a UUID-isolated test store.
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "--ledger-test-store"), args.indices.contains(index + 1),
                   UUID(uuidString: args[index + 1]) != nil, file == nil,
                   let csv = ProcessInfo.processInfo.environment["LOT_BILL_TEST_IMPORT_CSV"] {
                    do {
                        let loaded = try TabularFile.parse(data: Data(csv.utf8), name: "UI-Synthetic.csv")
                        file = loaded; mapping.firstRow = 2; mapping.lastRow = loaded.sheets[0].rows.count
                        if purpose == .history { mapping.useHistorySheet(loaded.sheets[0]); yearText = String(mapping.year) }
                        if purpose == .reconciliation { setMonth() }
                    } catch { self.error = error.localizedDescription }
                }
                #endif
            }
            .onChange(of: mapping) { _, _ in preview = nil }
            .onChange(of: yearText) { _, text in mapping.year = Int(text) ?? 0 }
            .onChange(of: mapping.sheetIndex) { _, index in
                if let file {
                    mapping.lastRow = max(1, file.sheets[index].rows.count); mapping.firstRow = min(2, mapping.lastRow)
                    if purpose == .history { mapping.useHistorySheet(file.sheets[index]); yearText = String(mapping.year) }
                }
                preview = nil
            }
            .onChange(of: month) { _, _ in setMonth() }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, UTType(filenameExtension: "xlsx") ?? .data]) { result in
                switch result {
                case .failure(let error): self.error = error.localizedDescription
                case .success(let url):
                    loading = true; error = nil; success = nil; preview = nil; file = nil
                    Task {
                        do {
                            let loaded = try await Task.detached(priority: .userInitiated) { try TabularFile.read(url: url) }.value
                            file = loaded; mapping.sheetIndex = 0
                            mapping.lastRow = max(1, loaded.sheets[0].rows.count); mapping.firstRow = min(2, mapping.lastRow)
                            mapping.categoryOverrides = [:]
                            if purpose == .history { mapping.useHistorySheet(loaded.sheets[0]); yearText = String(mapping.year) }
                            if purpose == .reconciliation { setMonth() }
                        } catch { self.error = error.localizedDescription }
                        loading = false
                    }
                }
            }
            .confirmationDialog("确认导入预览中的金额？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认提交") {
                    guard let preview else { return }
                    do { _ = try repository.importFile(preview); self.preview = nil; success = "导入成功，可在批次记录中查看来源和撤销影响。"; error = nil }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text(purpose == .history ? "历史汇总保留二级分类，按年度实际覆盖期间保存；2026 年仅覆盖 1 月 1 日至 8 月 31 日。" : "同月旧依据及其调整将停用，保存新版本后需要重新核对。对账金额本身不计入支出。") }
    }
    private func setMonth() {
        let period = LedgerPeriod.month(containing: month)
        mapping.startDay = period.start.rawValue; mapping.endDay = period.end.rawValue; mapping.precision = .month
        preview = nil
    }
    private func mappingSection(_ file: ImportFile) -> some View {
        Group {
            if purpose == .history {
                Section("2 · 年份与实际覆盖") {
                    Picker("工作表", selection: $mapping.sheetIndex) { ForEach(file.sheets) { Text($0.name).tag($0.id) } }
                    HStack { Text("年份"); TextField("YYYY", text: $yearText).ledgerKeyboard(.numberPad).multilineTextAlignment(.trailing).accessibilityIdentifier("import.year") }
                    if let period = try? mapping.historyColumns().first?.period {
                        Text("覆盖期间：\(period.start.rawValue) 至 \(period.end.rawValue)").accessibilityIdentifier("import.coverage")
                    }
                    Text("年度合计不拆分到各月，2026 年固定截至 8 月底。").font(.caption)
                }
                Section("3 · 第一、第二分类与年度金额") {
                    let columns = file.sheets[mapping.sheetIndex].columnCount
                    columnPicker("大类列（第一分类）", binding: $mapping.parentColumn, count: columns)
                    columnPicker("二级分类列（第二分类）", binding: $mapping.categoryColumn, count: columns, none: "无（仅大类）")
                    columnPicker("年度金额列", binding: $mapping.amountColumn, count: columns)
                    Text("已按表头设置列，请对照下方原始数据核实。").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("高级选项 · 数据行与金额格式") {
                        HStack { Text("起始行"); TextField("2", value: $mapping.firstRow, format: .number).ledgerKeyboard(.numberPad) }
                        HStack { Text("结束行"); TextField("末行", value: $mapping.lastRow, format: .number).ledgerKeyboard(.numberPad) }
                        Picker("金额格式", selection: $mapping.amountFormat) { ForEach(AmountFormat.allCases) { Text($0.title).tag($0) } }
                        Text("二级分类会保留；同一分类多行金额合并，新增分类将在预览中列出。").font(.caption)
                    }
                    DisclosureGroup("原始数据 · 前 5 行") {
                        let sheet = file.sheets[mapping.sheetIndex]
                        ForEach(1...max(1, min(5, sheet.rows.count)), id: \.self) { row in
                            Text("第 \(row) 行：" + [mapping.parentColumn, mapping.categoryColumn, mapping.amountColumn].filter { $0 >= 0 }.map { TabularFile.columnName($0) + "=" + sheet.cell(row: row, column: $0, fillMerged: $0 == mapping.parentColumn).text }.joined(separator: " · ")).font(.caption)
                        }
                    }
                }
            } else {
                Section("期间与映射 · 修改后请重新生成预览") {
                    Picker("工作表", selection: $mapping.sheetIndex) { ForEach(file.sheets) { Text($0.name).tag($0.id) } }
                    HStack { Text("起始行"); TextField("2", value: $mapping.firstRow, format: .number).ledgerKeyboard(.numberPad) }
                    HStack { Text("结束行"); TextField("末行", value: $mapping.lastRow, format: .number).ledgerKeyboard(.numberPad) }
                    let columns = file.sheets[mapping.sheetIndex].columnCount
                    columnPicker("大类列", binding: $mapping.parentColumn, count: columns, none: "无（单级分类）")
                    columnPicker("分类列", binding: $mapping.categoryColumn, count: columns)
                    columnPicker("金额列", binding: $mapping.amountColumn, count: columns)
                    Picker("金额格式", selection: $mapping.amountFormat) { ForEach(AmountFormat.allCases) { Text($0.title).tag($0) } }
                    MonthSelector(date: $month)
                    Text("\(mapping.startDay) 至 \(mapping.endDay)").font(.caption)
                    Picker("退款口径", selection: $mapping.basis) { Text("净支出（扣除退款）").tag("netExpense"); Text("消费总额（不扣退款）").tag("grossExpense") }
                    Text("消费总额仅比较真实消费流水，不可直接生成净支出调整。").font(.caption)
                }
            }
        }.onAppear { if purpose == .reconciliation { setMonth() } }
    }
    private func columnPicker(_ title: String, binding: Binding<Int>, count: Int, none: String? = nil) -> some View {
        Picker(title, selection: binding) {
            if let none { Text(none).tag(-1) }
            ForEach(0..<max(count, 3), id: \.self) { Text(TabularFile.columnName($0)).tag($0) }
        }
    }
    private func historyPreviewSection(_ p: ImportPreview) -> some View {
        Group {
            Section("4 · 核验合计 \(Money.display(p.total))") {
                Text("本次预览：\(p.mapping.historyPeriodLabel)支出，保留二级分类，\(p.file.sheets[p.mapping.sheetIndex].name)，第 \(p.mapping.firstRow)–\(p.mapping.lastRow) 行。").font(.caption)
                ForEach(p.issues, id: \.self) { Text($0).foregroundStyle(.red) }
                ForEach(p.summaries) { line in
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("\(line.period) · \(historyCategoryPath(line.categoryID, preview: p))", value: line.amountCents.map(Money.display) ?? "未提供")
                        if line.amountCents == nil { Text("未提供金额（不生成历史金额）").font(.caption).foregroundStyle(.secondary) }
                        if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        if let warning = line.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                        if let issue = line.issue { Text(issue).font(.caption).foregroundStyle(.red) }
                    }
                }
                Text("映射更改后请点“生成预览”，提交以此处显示的预览为准。").font(.caption)
                Button("确认导入") { confirm = true }.disabled(!p.canCommit).accessibilityIdentifier("import.commit")
            }
            Section("来源行") {
                let grouped = Dictionary(grouping: p.rows, by: \.row)
                ForEach(grouped.keys.sorted(), id: \.self) { number in
                    let cells = grouped[number] ?? []
                    let first = cells[0]
                    VStack(alignment: .leading, spacing: 5) {
                        Text("第 \(number) 行 · \(first.sourceCategory)")
                        if let id = first.categoryID { Text("→ " + historyCategoryPath(id, preview: p)).font(.caption) }
                        Text(cells.map { "\(cells.count > 1 ? ($0.period ?? "") + " " : "")\($0.amountCents.map(Money.display) ?? "未提供")" }.joined(separator: " · "))
                            .font(.subheadline)
                        if first.isTotal { Text("总计校验（不入账）").font(.caption) }
                        if cells.contains(where: \.formula) { Text("使用公式缓存值，请核对是否最新").font(.caption).foregroundStyle(.orange) }
                        ForEach(Array(Set(cells.compactMap(\.note))).sorted(), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(Set(cells.compactMap(\.issue))).sorted(), id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        if !first.isTotal {
                            if typeSize.isAccessibilitySize, let id = mapping.categoryOverrides[number] ?? first.categoryID {
                                Text("已映射：\(historyCategoryPath(id, preview: p))").font(.caption)
                            }
                            Picker("归入分类", selection: Binding(get: { mapping.categoryOverrides[number] ?? first.categoryID ?? "" }, set: { value in mapping.categoryOverrides[number] = p.newCategories.contains(where: { $0.id == value }) ? nil : value })) {
                                Text("请选择分类").tag("")
                                ForEach(repository.historyCategories(for: .expense)) { Text(repository.categoryPath($0.id)).tag($0.id) }
                                if let proposed = p.newCategories.first(where: { $0.id == first.categoryID }) {
                                    Text("新增：" + historyCategoryPath(proposed.id, preview: p)).tag(proposed.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func historyCategoryPath(_ id: String, preview: ImportPreview) -> String {
        if let category = preview.newCategories.first(where: { $0.id == id }) { return repository.categoryPath(category.parentID) + " · " + category.name }
        return repository.categoryPath(id)
    }
    private func previewSection(_ p: ImportPreview) -> some View {
        Section("确认预览 · 合计 \(Money.display(p.total))") {
            Text("本次预览：\(p.mapping.startDay) 至 \(p.mapping.endDay)，支出，\(p.file.sheets[p.mapping.sheetIndex].name)，第 \(p.mapping.firstRow)–\(p.mapping.lastRow) 行。").font(.caption)
            ForEach(p.issues, id: \.self) { Text($0).foregroundStyle(.red) }
            ForEach(p.rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text("第 \(row.row) 行 · \(row.sourceCategory)")
                    Text(row.isTotal ? "总计校验（不入账）" : row.amountCents.map(Money.display) ?? "未提供金额（不生成历史金额）").font(.subheadline)
                    if row.formula { Text("使用公式缓存值，请核对是否最新").font(.caption).foregroundStyle(.orange) }
                    if let issue = row.issue { Text(issue).font(.caption).foregroundStyle(.red) }
                    if !row.isTotal {
                        if typeSize.isAccessibilitySize, let id = mapping.categoryOverrides[row.row] ?? row.categoryID {
                            Text("已映射：\(repository.categoryPath(id))").font(.caption)
                        }
                        Picker("映射到", selection: Binding(get: { mapping.categoryOverrides[row.row] ?? row.categoryID ?? "" }, set: { mapping.categoryOverrides[row.row] = $0 })) {
                            Text("请选择分类").tag("")
                            ForEach(repository.selectableCategories(for: .expense)) { Text(repository.categoryPath($0.id)).tag($0.id) }
                        }
                    }
                }
            }
            Text("映射更改后请点“生成预览”，提交以此处显示的预览为准。").font(.caption)
            Button("确认导入") { confirm = true }.disabled(!p.canCommit).accessibilityIdentifier("import.commit")
        }
    }
}

struct ImportBatchesView: View {
    let repository: LedgerRepository
    @State private var pending: ImportBatch?
    @State private var editing: HistoricalSummary?
    @State private var impact = ""
    @State private var error: String?
    var body: some View {
        List {
            Section { Text(repository.historyCoverage).font(.footnote) }
            Section("历史账单 · 点击编辑") {
                ForEach(repository.histories.filter(\.isActive).sorted { ($0.startDay, $0.categoryID) > ($1.startDay, $1.categoryID) }) { history in
                    Button { editing = history } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent(repository.categoryPath(history.categoryID), value: Money.display(history.amountCents))
                                Text("\(history.startDay) 至 \(history.endDay)").font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "pencil").accessibilityHidden(true)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.borderless).accessibilityIdentifier("history.edit.\(history.categoryID)")
                }
            }
            if repository.batches.isEmpty { Text("尚无文件导入批次。") }
            ForEach(repository.batches) { batch in
                Section(batch.sourceName) {
                    Text("\(batch.purpose == "history" ? "历史汇总" : "月度对账") · \(batch.status == "committed" ? "已导入" : "已撤销")")
                    Text(batch.createdAt, style: .date).font(.caption)
                    if let audit = repository.audits.first(where: { $0.ownerID == batch.id && $0.kind == "import" }),
                       let receipt = try? JSONDecoder().decode(ImportReceipt.self, from: Data(audit.payload.utf8)) {
                        DisclosureGroup("来源：\(receipt.sheet)") {
                            ForEach(receipt.history, id: \.id) { history in
                                Text("\(history.start) 至 \(history.end) · \(repository.categoryPath(history.category)) · \(Money.display(history.amount))").font(.caption)
                            }
                            ForEach(receipt.rows) { row in Text("第 \(row.row) 行 · \(row.sourceCategory)\(row.period.map { " · " + $0 } ?? "") · \(row.amountCents.map(Money.display) ?? "未提供")").font(.caption) }
                        }
                    }
                    if batch.status == "committed" {
                        Button("预览撤销影响", role: .destructive) {
                            do { impact = try repository.undoImpact(batch); pending = batch } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
        }.navigationTitle("历史账单与导入批次")
            .sheet(item: $editing) { history in HistoryEditor(repository: repository, history: history) }
            .confirmationDialog("撤销导入批次", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("确认撤销", role: .destructive) {
                    guard let pending else { return }
                    do { try repository.undoBatch(pending) } catch { self.error = error.localizedDescription }
                    self.pending = nil
                }
            } message: { Text(impact) }
            .alert("无法撤销", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
}

struct HistoryEditor: View {
    let repository: LedgerRepository
    let history: HistoricalSummary
    @State private var revision: Int
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var categoryID: String
    @State private var startDay: String
    @State private var endDay: String
    @State private var error: String?

    init(repository: LedgerRepository, history: HistoricalSummary) {
        self.repository = repository; self.history = history; _revision = State(initialValue: repository.revision)
        _amount = State(initialValue: Money.decimal(history.amountCents))
        _categoryID = State(initialValue: history.categoryID)
        _startDay = State(initialValue: history.startDay); _endDay = State(initialValue: history.endDay)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("历史汇总") {
                    TextField("金额", text: $amount).ledgerKeyboard(.decimalPad).accessibilityIdentifier("history.amount")
                    Picker("分类", selection: $categoryID) {
                        ForEach(repository.categories.filter { category in category.id == history.categoryID || repository.historyCategories(for: EntryKind(rawValue: history.kindRaw) ?? .expense).contains(where: { $0.id == category.id }) }) { category in
                            Text(repository.categoryPath(category.id)).tag(category.id)
                        }
                    }
                    TextField("开始日期 YYYY-MM-DD", text: $startDay).accessibilityIdentifier("history.start")
                    TextField("结束日期 YYYY-MM-DD", text: $endDay).accessibilityIdentifier("history.end")
                    Text("修改后统计重新计算，相关对账标记为待核对。原始导入记录保留；已修改的批次不能自动撤销。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("history.error") }
            }.formStyle(.grouped).navigationTitle("编辑历史账单")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                try repository.editHistory(id: history.id, amount: amount, categoryID: categoryID, startDay: startDay, endDay: endDay, expectedRevision: revision)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("history.save")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 400)
        #endif
    }
}

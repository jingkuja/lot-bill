import SwiftUI
import Charts
import UniformTypeIdentifiers

struct LedgerRootView: View {
    @State var repository: LedgerRepository
    var body: some View {
        TabView {
            OverviewView(repository: repository)
                .tabItem { Label("首页", systemImage: "square.grid.2x2") }
            EntriesView(repository: repository)
                .tabItem { Label("流水", systemImage: "list.bullet.rectangle") }
            ReportsView(repository: repository)
                .tabItem { Label("统计", systemImage: "chart.bar.xaxis") }
            LedgerSettingsView(repository: repository)
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .id(repository.restoreGeneration)
        .tint(.teal)
    }
}

struct MonthSelector: View {
    @Binding var date: Date
    var annual = false
    @State private var choosingMonth = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var title: String { annual ? String(LedgerDay(date: date).rawValue.prefix(4)) : LedgerDay(date: date).month }
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    monthButton
                    HStack {
                        previous
                        Spacer()
                        next
                    }
                }
            } else {
                HStack {
                    previous
                    Spacer()
                    monthButton
                    Spacer()
                    next
                }
            }
        }.buttonStyle(.bordered).padding(.vertical, 4)
            .sheet(isPresented: $choosingMonth) { MonthSelectionSheet(date: $date, annual: annual) }
    }
    private var monthButton: some View {
        Button { choosingMonth = true } label: {
            Label(annual ? title + " 年" : title.replacingOccurrences(of: "-", with: " 年 ") + " 月", systemImage: "calendar")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .accessibilityLabel(annual ? "选择年份" : "选择月份")
        .accessibilityValue(title)
        .accessibilityHint(annual ? "打开年份选择" : "打开年份和月份选择")
        .accessibilityIdentifier("month.choose")
    }
    private var previous: some View {
        Button { move(-1) } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
        }
        .accessibilityLabel(annual ? "上一年" : "上个月")
    }
    private var next: some View {
        Button { move(1) } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
        }
        .accessibilityLabel(annual ? "下一年" : "下个月")
    }
    private func move(_ value: Int) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        let first = LedgerPeriod.month(containing: date).start.date()
        if let next = c.date(byAdding: annual ? .year : .month, value: value, to: first),
           (1900...2100).contains(c.component(.year, from: next)) { date = next }
    }
}

private struct MonthSelectionSheet: View {
    @Binding var date: Date
    let annual: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var yearText: String
    private var year: Int? {
        guard let value = Int(yearText), (1900...2100).contains(value) else { return nil }
        return value
    }
    init(date: Binding<Date>, annual: Bool) {
        _date = date
        self.annual = annual
        _yearText = State(initialValue: String(LedgerDay(date: date.wrappedValue).rawValue.prefix(4)))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("年份")
                        TextField("1900–2100", text: $yearText)
                            .textFieldStyle(.roundedBorder).ledgerKeyboard(.numberPad)
                            .accessibilityLabel("年份").accessibilityIdentifier("month.year")
                        Stepper("年份", onIncrement: { shiftYear(1) }, onDecrement: { shiftYear(-1) }).labelsHidden()
                    }
                    Text(year == nil ? "请输入 1900–2100 之间的年份。" : annual ? "输入年份后点击确定。" : "可直接输入年份，点击月份切换。")
                        .font(.caption).foregroundStyle(year == nil ? Color.red : Color.secondary)
                    if !annual {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78))], spacing: 12) {
                            ForEach(1...12, id: \.self) { month in
                                let selected = year.map { String(format: "%04d-%02d", $0, month) == LedgerDay(date: date).month } ?? false
                                Button { select(month) } label: {
                                    Text("\(month) 月").frame(maxWidth: .infinity, minHeight: 32)
                                        .fontWeight(selected ? .bold : .regular)
                                }
                                .buttonStyle(.bordered).tint(selected ? .teal : .secondary)
                                .disabled(year == nil)
                                .accessibilityAddTraits(selected ? [.isSelected] : [])
                                .accessibilityIdentifier("month.option.\(month)")
                            }
                        }
                    }
                    Button(annual ? "回到今年" : "回到本月") { date = LedgerPeriod.month(containing: Date()).start.date(); dismiss() }
                        .accessibilityIdentifier("month.today")
                }.padding(24)
            }
            .navigationTitle(annual ? "选择年份" : "选择月份")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if annual {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确定") { select(Calendar(identifier: .gregorian).component(.month, from: date)) }
                            .disabled(year == nil).accessibilityIdentifier("year.confirm")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 390, height: annual ? 230 : 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
    private func shiftYear(_ delta: Int) {
        guard let year else { return }
        yearText = String(min(2100, max(1900, year + delta)))
    }
    private func select(_ month: Int) {
        guard let year, let day = try? LedgerDay(String(format: "%04d-%02d-01", year, month)) else { return }
        date = day.date(); dismiss()
    }
}

private struct TotalsSection: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let result: Result<LedgerTotals, Error>
    var body: some View {
        switch result {
        case .failure(let error):
            ContentUnavailableView("暂不能计算", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
        case .success(let total):
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(total.unsplitPeriods.isEmpty ? "本月净支出" : "净支出 · 历史未按月拆分")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "creditcard.circle.fill")
                            .foregroundStyle(.teal.opacity(0.8))
                    }
                    Text(total.unsplitPeriods.isEmpty ? Money.display(total.netExpense) : "暂不完整")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .minimumScaleFactor(0.5)
                        .accessibilityIdentifier("summary.expense")
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.teal.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.teal.opacity(0.18), lineWidth: 1)
                )

                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    metricCard("月度收入", total.income, identifier: "summary.income", color: .teal, icon: "arrow.down.left")
                    metricCard("收支结余", total.surplus, identifier: "summary.surplus", color: total.surplus >= 0 ? .teal : .orange, icon: "equal.circle")
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("消费 \(Money.display(total.consumption)) · 退款 \(Money.display(total.refunds))")
                        .font(.footnote)
                    if total.adjustment != 0 {
                        Text("· 调整 \(Money.display(total.adjustment))").font(.footnote)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)

                if !total.unsplitPeriods.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已知净支出 \(Money.display(total.netExpense))").font(.subheadline).fontWeight(.medium)
                        Label("部分历史期间未按月拆分，以上仅为已知金额。", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.orange)
                        ForEach(total.unsplitPeriods, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
                }
            }.padding(.vertical, 6)
        }
    }
    private func metricCard(_ name: String, _ value: Int64, identifier: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            Text(Money.display(value))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.07)))
    }
}

struct OverviewView: View {
    let repository: LedgerRepository
    @State private var month = Date()
    @State private var showEntry = false
    private var period: LedgerPeriod { .month(containing: month) }
    var body: some View {
        NavigationStack {
            List {
                if let notice = repository.restoreNotice {
                    Section {
                        Text(notice).accessibilityIdentifier("restore.notice")
                        Button("知道了") { repository.restoreNotice = nil }
                    }
                }
                Section { MonthSelector(date: $month) }
                Section {
                    TotalsSection(result: Result { try LedgerStatistics.calculate(period: period, entries: repository.entries, histories: repository.histories, adjustments: repository.adjustments, parents: repository.categoryParents) })
                } header: { Text("这个月 · 人民币") } footer: {
                    Text("按已录入记录统计；收支结余不是账户余额。")
                }
                Section {
                    Button { showEntry = true } label: {
                        HStack {
                            Label("记一笔", systemImage: "plus.circle.fill")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }.accessibilityIdentifier("entry.add")
                    NavigationLink { AIAssistanceView(repository: repository) } label: {
                        Label("AI 辅助记账", systemImage: "sparkles")
                    }.accessibilityIdentifier("ai.open")
                }
                Section {
                    NavigationLink { ReconciliationListView(repository: repository) } label: {
                        HStack {
                            Label("月度对账", systemImage: "checkmark.seal.fill")
                            Spacer()
                            let pendingCount = repository.statements.filter { $0.isActive && !$0.isReviewed }.count
                            if pendingCount > 0 {
                                Text("\(pendingCount) 项待核对")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.orange)
                            } else {
                                Text("已就绪")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("最近记录") {
                    let recent = repository.entries.filter { period.contains($0.day) }
                    if recent.isEmpty {
                        ContentUnavailableView("从今天第一笔开始", systemImage: "square.and.pencil", description: Text("历史账单可以稍后整理，先记下当下的收入与支出。"))
                    }
                    ForEach(Array(recent.prefix(8))) { entry in
                        NavigationLink { EntryDetailView(repository: repository, entry: entry) } label: { EntryRow(repository: repository, entry: entry) }
                    }
                }
                if repository.preferences.backupDue() {
                    Section {
                        NavigationLink { BackupRestoreView(repository: repository) } label: {
                            Label(repository.preferences.backupStamp == nil ? "尚未导出完整备份" : "完整备份已到提醒时间", systemImage: "externaldrive.badge.exclamationmark")
                        }
                    }
                }
            }
            .navigationTitle("Lot Bill")
            .sheet(isPresented: $showEntry) { EntryEditor(repository: repository) }
        }
    }
}

struct EntryRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let repository: LedgerRepository
    let entry: LedgerEntry
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: entry.kind == .transfer ? entry.kind.symbol : CategoryGlyph.icon(for: repository.categoryName(entry.categoryID)))
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(entry.kind.themeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(entry.kind.themeColor)
                .accessibilityHidden(true)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.kind == .transfer ? "账户转账" : repository.categoryName(entry.categoryID))
                            .font(.system(.body, design: .rounded, weight: .medium))
                        if entry.kind != .expense {
                            Text(entry.kind.title)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(entry.kind.themeColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(entry.kind.themeColor)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(entry.kind == .transfer ? "\(repository.accountName(entry.accountID)) → \(repository.accountName(entry.destinationAccountID))" : repository.accountName(entry.accountID))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(entry.day).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !entry.note.isEmpty {
                        Text(entry.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                    let prefix = entry.kind == .income ? "+" : (entry.kind == .expense ? "-" : "")
                    Text(prefix + Money.display(entry.amountCents))
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(entry.kind == .income ? Color.teal : (entry.kind == .expense ? Color.primary : Color.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }.padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct EntriesView: View {
    let repository: LedgerRepository
    @State private var month = Date()
    @State private var search = ""
    @State private var kind = "all"
    @State private var category = "all"
    @State private var account = "all"
    @State private var showEntry = false
    private var filtered: [LedgerEntry] {
        repository.filteredEntries(period: .month(containing: month), kind: kind, category: category, account: account, search: search)
    }

    var body: some View {
        // Filter once per render, then group once. Re-filtering the full ledger
        // inside every day section makes large-list searches unnecessarily slow.
        let matches = filtered
        let days = Dictionary(grouping: matches, by: \.day)
        NavigationStack {
            List {
                Section { MonthSelector(date: $month) }
                Section {
                    DisclosureGroup("筛选 · \(matches.count) 笔") {
                        Picker("类型", selection: $kind) {
                            Text("全部").tag("all")
                            ForEach(EntryKind.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        Picker("分类", selection: $category) {
                            Text("全部").tag("all")
                            ForEach(repository.categories) { c in
                                Text(repository.categoryPath(c.id)).tag(c.id)
                            }
                        }
                        Picker("账户", selection: $account) {
                            Text("全部").tag("all")
                            ForEach(repository.accounts) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                if matches.isEmpty {
                    ContentUnavailableView("还没有匹配的流水", systemImage: "list.bullet.rectangle", description: Text("调整月份或筛选条件，也可以补记过去的交易。"))
                }
                let monthlyAdjustments = repository.adjustments.filter { $0.isActive && $0.month == LedgerDay(date: month).month && (category == "all" || $0.categoryID == category || repository.categoryParents[$0.categoryID] == category) }
                if !monthlyAdjustments.isEmpty && account == "all" && (kind == "all" || kind == "expense") && search.isEmpty {
                    Section("月度调整 · 不属于每日交易") {
                        ForEach(monthlyAdjustments) { adjustment in
                            VStack(alignment: .leading) {
                                LabeledContent(repository.categoryPath(adjustment.categoryID), value: Money.display(adjustment.signedCents))
                                Text("\(adjustment.month) · 修订 \(adjustment.revision) · \(adjustment.reason)").font(.caption)
                            }
                        }
                    }
                }
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Section(day) {
                        ForEach(days[day] ?? []) { entry in
                            NavigationLink { EntryDetailView(repository: repository, entry: entry) } label: { EntryRow(repository: repository, entry: entry) }
                        }
                    }
                }
            }
            .ledgerSearchable(text: $search)
            .navigationTitle("流水")
            .toolbar { Button { showEntry = true } label: { Label("记一笔", systemImage: "plus") }.accessibilityIdentifier("entries.add") }
            .sheet(isPresented: $showEntry) { EntryEditor(repository: repository) }
        }
    }
}

struct EntryDetailView: View {
    let repository: LedgerRepository
    let entry: LedgerEntry
    @Environment(\.dismiss) private var dismiss
    @State private var edit = false
    @State private var confirmDelete = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                LabeledContent(entry.kind.title, value: Money.display(entry.amountCents)).font(.title2)
                LabeledContent("日期", value: entry.day)
                if entry.kind != .transfer { LabeledContent("分类", value: repository.categoryPath(entry.categoryID)) }
                LabeledContent(entry.kind == .transfer ? "转出账户" : "账户", value: repository.accountName(entry.accountID))
                if entry.kind == .transfer { LabeledContent("转入账户", value: repository.accountName(entry.destinationAccountID)) }
                if entry.kind == .refund, let original = repository.entries.first(where: { $0.id == entry.originalEntryID }) {
                    LabeledContent("原支出", value: "\(original.day) · \(Money.display(original.amountCents))")
                }
                if let evidence = repository.historicalRefundEvidence(for: entry),
                   let history = repository.histories.first(where: { $0.id == evidence.historyID }) {
                    LabeledContent("退款来源", value: "历史消费 · " + repository.categoryPath(history.categoryID))
                    Text("\(history.startDay) 至 \(history.endDay)").font(.caption)
                    Text("批次：" + (repository.batches.first { $0.id == history.batchID }?.sourceName ?? "历史批次"))
                    LabeledContent("凭据说明", value: evidence.reference)
                    LabeledContent("退款原因", value: evidence.reason)
                }
                if !entry.note.isEmpty { Text(entry.note).accessibilityIdentifier("entry.detail.note") }
            }
            Section {
                Button("编辑记录") { edit = true }.accessibilityIdentifier("entry.edit")
                Button("删除记录", role: .destructive) { confirmDelete = true }.accessibilityIdentifier("entry.delete")
            }
        }
        .ledgerForm()
        .navigationTitle("记录详情")
        .sheet(isPresented: $edit) { EntryEditor(repository: repository, entry: entry) }
        .confirmationDialog("删除这笔记录？统计会同时更新。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) {
                do { try repository.delete(entry); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct ReportsView: View {
    let repository: LedgerRepository
    @State private var date = Date()
    @State private var annual = false
    @State private var exportDocument: LedgerFileDocument?
    @State private var exporting = false
    @State private var exportType: UTType = UTType(filenameExtension: "xlsx") ?? .data
    @State private var exportName = "统计"
    @State private var exportMessage: String?
    private var period: LedgerPeriod { annual ? .year(containing: date) : .month(containing: date) }
    private var result: Result<LedgerTotals, Error> {
        Result { try LedgerStatistics.calculate(period: period, entries: repository.entries, histories: repository.histories, adjustments: repository.adjustments, parents: repository.categoryParents) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("统计范围", selection: $annual) { Text("月度").tag(false); Text("年度").tag(true) }.pickerStyle(.segmented)
                    MonthSelector(date: $date, annual: annual)
                    Text("\(period.start.rawValue) 至 \(period.end.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink("月度对账") { ReconciliationListView(repository: repository) }
                    NavigationLink("历史期间与导入批次") { ImportBatchesView(repository: repository) }
                }
                Section("已录入收支") { TotalsSection(result: result) }
                if case .success(let total) = result {
                    let values = (annual ? total.byFirstCategory : total.byCategory).sorted { $0.value > $1.value }
                    Section(annual ? "第一分类年度净支出" : "分类净支出") {
                        if values.isEmpty { Text("录入支出后，这里会展示分类分布。").foregroundStyle(.secondary) }
                        if !values.isEmpty {
                            Chart(Array(values.prefix(8)), id: \.key) { item in
                                BarMark(x: .value("金额（元）", Double(item.value) / 100), y: .value("分类", repository.categoryPath(item.key)))
                                    .foregroundStyle(.teal)
                            }.frame(height: CGFloat(min(values.count, 8) * 38 + 35))
                                .accessibilityLabel("分类净支出图，下方提供精确金额列表")
                        }
                        ForEach(values, id: \.key) { item in
                            if annual {
                                DisclosureGroup {
                                    AnnualCategoryBreakdown(repository: repository, categoryID: item.key, period: period)
                                } label: {
                                    LabeledContent(repository.categoryPath(item.key), value: Money.display(item.value))
                                }.accessibilityIdentifier("report.group.\(item.key)")
                            } else {
                                LabeledContent(repository.categoryPath(item.key), value: Money.display(item.value))
                            }
                        }
                    }
                }
                Section {
                    Text("转账不计入收入或支出；退款按退款发生日期冲减原分类。历史汇总保留原期间，月度对账依据不直接计入支出。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("统计")
                .toolbar {
                    ToolbarItem {
                        Menu {
                            Button("Excel 工作簿（.xlsx）") { exportStatistics(excel: true) }
                            Button("通用表格（.csv）") { exportStatistics(excel: false) }
                        } label: { Label("导出统计", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("report.export")
                        .disabled({ if case .failure = result { return true }; return false }())
                    }
                }
                .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { outcome in
                    switch outcome {
                    case .success: exportMessage = "统计数据已导出。"
                    case .failure(let error): if (error as NSError).code != NSUserCancelledError { exportMessage = error.localizedDescription }
                    }
                }
                .alert("统计导出", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
                    Button("好") { exportMessage = nil }
                } message: { Text(exportMessage ?? "") }
        }
    }
    private func exportStatistics(excel: Bool) {
        do {
            let report = try repository.statisticsExport(period: period)
            exportDocument = LedgerFileDocument(data: excel ? try report.xlsx() : report.csv())
            exportType = excel ? (UTType(filenameExtension: "xlsx") ?? .data) : .commaSeparatedText
            exportName = "LotBill-" + (annual ? "年度统计-" + String(period.start.rawValue.prefix(4)) : "月度统计-" + period.start.month)
            exporting = true
        } catch { exportMessage = error.localizedDescription }
    }

}

private struct AnnualCategoryBreakdown: View {
    let repository: LedgerRepository
    let categoryID: String
    let period: LedgerPeriod
    var body: some View {
        let parents = repository.categoryParents
        let histories = repository.histories.filter {
            $0.isActive && $0.kindRaw == "expense" && (parents[$0.categoryID] ?? $0.categoryID) == categoryID &&
            period.contains($0.startDay) && period.contains($0.endDay)
        }.sorted { $0.startDay < $1.startDay }
        ForEach(histories) { history in
            LabeledContent(repository.categoryName(history.categoryID), value: Money.display(history.amountCents))
        }
        let result = Result { try LedgerStatistics.calculate(period: period, entries: repository.entries, adjustments: repository.adjustments, parents: parents) }
        if case .success(let details) = result {
            ForEach(details.byCategory.keys.filter { (parents[$0] ?? $0) == categoryID }.sorted(), id: \.self) { id in
                LabeledContent(id == categoryID ? "大类流水及历史退款" : repository.categoryName(id) + " · 明细及调整", value: Money.display(details.byCategory[id] ?? 0))
            }
        }
        Text("年度汇总不拆分到月份；日常金额包含退款与有效调整。").font(.caption).foregroundStyle(.secondary)
    }
}

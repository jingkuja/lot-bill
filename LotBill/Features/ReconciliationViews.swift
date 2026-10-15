import SwiftUI

struct ReconciliationListView: View {
    let repository: LedgerRepository
    var body: some View {
        List {
            Section {
                NavigationLink("年度月份与分类覆盖") { MonthlyCoverageView(repository: repository) }.accessibilityIdentifier("coverage.open")
                NavigationLink("导入月度文件") { HistoryImportView(repository: repository, purpose: .reconciliation) }
                NavigationLink("手动填写分类合计") { ManualStatementView(repository: repository) }.accessibilityIdentifier("reconciliation.manual")
                Text("人民币 · 全部账户。只核对已提供的分类；空白表示未提供。每月仅一个有效版本，新版本会停用旧版本调整。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(repository.statements) { statement in
                NavigationLink {
                    ReconciliationDetailView(repository: repository, statement: statement)
                } label: {
                    VStack(alignment: .leading) {
                        Text("\(statement.month) · 版本 \(statement.version)")
                        Text(!statement.isActive ? "历史版本" : statement.isReviewed ? "已核对（范围及保留差异见详情）" : "待核对")
                            .font(.caption).foregroundStyle(statement.isActive && !statement.isReviewed ? .orange : .secondary)
                    }
                }
            }
        }.navigationTitle("月度对账")
    }
}

private struct ManualStatementView: View {
    let repository: LedgerRepository
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var basis = "netExpense"
    @State private var amounts: [String: String] = [:]
    @State private var error: String?
    @State private var pending: [String: Int64]?
    init(repository: LedgerRepository, month: Date = Date()) {
        self.repository = repository; _date = State(initialValue: month)
    }
    var body: some View {
        Form {
            Section("范围") {
                MonthSelector(date: $date)
                Text("\(LedgerDay(date: date).month) · CNY · 全部账户")
                Picker("退款口径", selection: $basis) { Text("净支出").tag("netExpense"); Text("消费总额").tag("grossExpense") }
                Text("空白为未提供；明确 0 才按零核对。净支出允许因退款出现负数。").font(.caption)
            }
            Section("分类金额（元）") {
                ForEach(repository.selectableCategories(for: .expense)) { category in
                    VStack(alignment: .leading) {
                        Text(repository.categoryPath(category.id)).font(.subheadline)
                        TextField("未提供", text: Binding(get: { amounts[category.id] ?? "" }, set: { amounts[category.id] = $0 }))
                            .ledgerKeyboard(.numbersAndPunctuation).accessibilityIdentifier("statement.amount.\(category.id)")
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }

        }.navigationTitle("手动对账依据")
            .scrollDismissesKeyboard(.interactively)
            .toolbar { Button("保存") { prepare() }.accessibilityIdentifier("statement.save") }
            .confirmationDialog("保存 \(LedgerDay(date: date).month) 对账依据", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("确认保存依据") {
                    guard let pending else { return }
                    do { _ = try repository.saveStatement(month: LedgerDay(date: date).month, values: pending, basis: basis); dismiss() }
                    catch { self.error = error.localizedDescription }
                    self.pending = nil
                }
            } message: {
                Text("\(pending?.count ?? 0) 个分类；\(basis == "netExpense" ? "净支出" : "消费总额")，全部账户、人民币。同月旧版本及其调整将停用，请重新核对。")
            }
    }
    private func prepare() {
        do {
            var values: [String: Int64] = [:]
            for (id, text) in amounts {
                if let amount = try AmountFormat.decimalPoint.parse(text, signed: basis == "netExpense") { values[id] = amount }
            }
            guard !values.isEmpty else { throw LedgerError.invalid("请填写至少一个分类金额。") }
            pending = values; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ReconciliationDetailView: View {
    let repository: LedgerRepository
    let statement: ReconciliationStatement
    @State private var reason = ""
    @State private var error: String?
    @State private var confirmReview = false
    private var result: Result<[ReconciliationDifference], Error> { Result { try repository.differences(for: statement) } }
    var body: some View {
        List {
            Section {
                Text("\(statement.month) · v\(statement.version) · \(statement.isActive ? "当前有效" : "历史版本")")
                Text("全部账户 · CNY · \(statement.basis == "netExpense" ? "净支出" : "消费总额（不可自动调整）")").font(.footnote)
                Text(statement.isReviewed ? "已核对，核对范围和保留差异见下方记录" : "待核对")
                if !statement.isActive { Text("此版本只读。下方账本值为当前值，原核对快照见记录。").font(.caption) }
            }
            switch result {
            case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
            case .success(let rows):
                ForEach(rows.filter { $0.external != nil }) { row in
                    NavigationLink { ReconciliationItemView(repository: repository, statement: statement, itemID: row.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(repository.categoryPath(row.item.categoryID))
                            Text("依据 \(row.external.map(Money.display) ?? "未提供") · 差额 \(row.difference.map(Money.display) ?? "—")").font(.caption)
                            Text("账本 \(Money.display(row.recorded)) · 调整 \(Money.display(row.adjustment))").font(.caption).foregroundStyle(.secondary)
                            if let issue = row.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                DisclosureGroup("未提供分类（\(rows.filter { $0.external == nil }.count)）") {
                    ForEach(rows.filter { $0.external == nil }) { row in
                        Text("\(repository.categoryPath(row.item.categoryID)) · 未提供").font(.caption)
                    }
                }
            }
            if statement.isActive {
                Section("核对确认") {
                    TextField("保留未解决差异的原因（有差异时必填）", text: $reason, axis: .vertical)
                    Button("标记已核对") { confirmReview = true }.accessibilityIdentifier("statement.review")
                    Text("未提供分类不纳入核对；任何相关流水或调整变化都会重新标记待核对。").font(.caption)
                }
            }
            Section("来源与核对记录") {
                if let batch = repository.batches.first(where: { $0.id == statement.batchID }) { Text("来源：\(batch.sourceName)") }
                else { Text("来源：手动填写") }
                ForEach(repository.audits.filter { $0.ownerID == statement.id }) { audit in
                    DisclosureGroup(audit.kind == "review" ? "核对快照" : audit.kind == "adjustment" ? "调整修订" : "依据版本") {
                        Text(audit.createdAt, style: .date).font(.caption)
                        Text(audit.payload).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("对账明细")
            .confirmationDialog("确认已检查已提供分类的差异？", isPresented: $confirmReview, titleVisibility: .visible) {
                Button("确认核对") {
                    do { try repository.reviewStatement(statement, unresolvedReason: reason); error = nil } catch { self.error = error.localizedDescription }
                }
            }
    }
}

private struct ReconciliationItemView: View {
    let repository: LedgerRepository
    let statement: ReconciliationStatement
    let itemID: String
    @State private var showEntry = false
    @State private var reason = ""
    @State private var pending: Int64?
    @State private var error: String?
    private var row: ReconciliationDifference? { try? repository.differences(for: statement).first { $0.id == itemID } }
    var body: some View {
        List {
            if let row {
                Section("\(statement.month) · \(repository.categoryPath(row.item.categoryID))") {
                    LabeledContent("原始账本合计", value: Money.display(row.recorded))
                    LabeledContent("有效月度调整", value: Money.display(row.adjustment))
                    LabeledContent("外部对账合计", value: row.external.map(Money.display) ?? "未提供")
                    LabeledContent("当前差额", value: row.difference.map(Money.display) ?? "不可计算")
                    if let issue = row.issue { Text(issue).foregroundStyle(.orange) }
                }
                Section("分类流水 · 可编辑、删除或补录") {
                    ForEach(repository.entries.filter { $0.categoryID == row.item.categoryID && $0.day.hasPrefix(statement.month) }) { entry in
                        NavigationLink { EntryDetailView(repository: repository, entry: entry) } label: { EntryRow(repository: repository, entry: entry) }
                    }
                    if statement.isActive { Button("补录真实交易") { showEntry = true }.accessibilityIdentifier("reconciliation.addEntry") }
                }
                if statement.isActive, let suggested = row.suggestedAdjustment {
                    Section("没有明细时修订月度调整") {
                        Text("建议有效调整：\(Money.display(suggested))（\(suggested > 0 ? "增加支出" : suggested < 0 ? "减少支出" : "归零")）。此金额已排除该项旧调整，确认后替换旧版本。").font(.footnote)
                        if row.adjustment != suggested { Text("补入真实明细后，请重新确认旧调整是否需要归零或修订。").font(.caption).foregroundStyle(.orange) }
                        TextField("调整原因", text: $reason, axis: .vertical).accessibilityIdentifier("adjustment.reason")
                        Button("确认调整金额") { pending = suggested }.accessibilityIdentifier("adjustment.prepare")
                    }
                }
                if statement.isActive, row.issue != nil, row.adjustment != 0 {
                    Section("清理旧调整") {
                        Text("当前差额不可按子类计算。核实原调整后，可将旧调整归零，避免与大类退款重复冲减。").font(.footnote)
                        TextField("归零原因", text: $reason, axis: .vertical)
                        Button("将旧调整归零") { pending = 0 }
                    }
                }
                Section("调整修订历史") {
                    ForEach(repository.adjustments.filter { $0.statementItemID == itemID }.sorted { $0.revision > $1.revision }) { adjustment in
                        VStack(alignment: .leading) {
                            Text("v\(adjustment.revision) · \(Money.display(adjustment.signedCents)) · \(adjustment.isActive ? "有效" : "已停用")")
                            Text(adjustment.reason).font(.caption)
                        }
                    }
                }
            } else { Text("对账项目不可计算，请返回查看错误。") }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("分类差异")
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showEntry) {
                EntryEditor(repository: repository, initialDraft: EntryDraft(day: statement.month + "-01", categoryID: row?.item.categoryID))
            }
            .confirmationDialog("将该项有效调整修订为 \(pending.map(Money.display) ?? "")？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("确认修订") {
                    guard let pending else { return }
                    do { try repository.reviseAdjustment(itemID: itemID, expectedCents: pending, reason: reason); error = nil }
                    catch { self.error = error.localizedDescription }
                    self.pending = nil
                }
            } message: { Text("来源为 \(statement.month) 对账版本 \(statement.version)。不会创建虚构的每日交易。") }
    }
}

struct MonthlyCoverageView: View {
    let repository: LedgerRepository
    @State private var year = Calendar(identifier: .gregorian).component(.year, from: Date())
    var body: some View {
        List {
            Section {
                Stepper("\(String(year)) 年", value: $year, in: 1900...2100).accessibilityIdentifier("coverage.year")
                Text("按第一分类查看历史覆盖与对账范围。无记录不代表零支出；已核对仅限已提供分类，可能保留差异。").font(.footnote)
            }
            ForEach(1...12, id: \.self) { number in
                let month = String(format: "%04d-%02d", year, number)
                CoverageMonthRow(repository: repository, month: month)
            }
        }.navigationTitle("月度覆盖")
    }
}
private struct CoverageMonthRow: View {
    let repository: LedgerRepository
    let month: String
    var body: some View {
        let result = Result { try repository.coverage(month: month) }
        if case .success(let groups) = result {
            let statement = repository.statements.first { $0.month == month && $0.isActive }
            DisclosureGroup {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(group.name, value: group.status)
                        if group.history != nil && group.supplied > 0 {
                            Text("\(group.reviewed ? "已核对" : "待核对") · \(group.supplied)/\(group.expected) 个分类；历史不可分摊").font(.caption)
                        }
                        Text(group.hasEntries ? "有日常明细" : "未记录明细（不代表零支出）").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let statement {
                    NavigationLink("查看本月对账范围与差异") { ReconciliationDetailView(repository: repository, statement: statement) }
                } else if let day = try? LedgerDay(month + "-01") {
                    NavigationLink("填写本月对账依据") { ManualStatementView(repository: repository, month: day.date()) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(month)
                    Text(groups.contains { $0.history != nil } ? "含历史汇总 · 逐类查看覆盖" : statement == nil ? "未提供对账依据" : statement!.isReviewed ? "已核对已提供分类 · 范围见详情" : "待核对").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("coverage.month.\(month)")
        } else if case .failure(let error) = result { Text(error.localizedDescription).foregroundStyle(.red) }
    }
}

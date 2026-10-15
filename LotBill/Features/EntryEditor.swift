import SwiftUI

struct EntryEditor: View {
    let repository: LedgerRepository
    let entry: LedgerEntry?
    let requiresAIReview: Bool
    @State private var aiReviewed = false
    @Environment(\.dismiss) private var dismiss
    @State private var options: EntryEditorOptions
    @State private var draft: EntryDraft
    @State private var date: Date
    @State private var error: String?
    @State private var success: String?
    @State private var historyRefund = false
    @FocusState private var amountFocused: Bool

    init(repository: LedgerRepository, entry: LedgerEntry? = nil, initialDraft: EntryDraft? = nil, requiresAIReview: Bool = false) {
        self.repository = repository; self.entry = entry; self.requiresAIReview = requiresAIReview
        let initial = entry.map { repository.draft(for: $0) } ?? initialDraft ?? repository.quickDraft()
        _historyRefund = State(initialValue: repository.histories.contains { $0.id == initial.originalEntryID })
        _options = State(initialValue: EntryEditorOptions(repository: repository, kind: initial.kind, entry: entry, historyRefund: repository.histories.contains { $0.id == initial.originalEntryID }))
        _draft = State(initialValue: initial)
        _date = State(initialValue: (try? LedgerDay(initial.day))?.date() ?? Date())
    }
    var body: some View {
        editor
            .onChange(of: aiReviewed) { _, _ in error = nil }
            .onChange(of: repository.revision) { _, _ in refreshOptions() }
            .onChange(of: draft.kind) { _, kind in
                if !repository.selectableCategories(for: kind).contains(where: { $0.id == draft.categoryID }) {
                    draft.categoryID = repository.quickDraft(kind: kind).categoryID
                }
                draft.originalEntryID = nil; draft.destinationAccountID = nil
                if kind != .refund { historyRefund = false }
                refreshOptions()
            }
            .onChange(of: historyRefund) { _, _ in
                draft.originalEntryID = nil; draft.refundReference = ""; draft.refundReason = ""
                refreshOptions()
            }
    }

    private var kindColor: Color {
        draft.kind.themeColor
    }

    @ViewBuilder private var editor: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: entry == nil ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.title2).foregroundStyle(kindColor)
                Text(entry == nil ? "记一笔" : "编辑记录").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            ScrollView {
                Form { fields }
                    .formStyle(.columns)
                    .textFieldStyle(.roundedBorder)
                    .padding(20)
            }
            Divider()
            HStack {
                if entry == nil && !requiresAIReview && (draft.kind == .expense || draft.kind == .income) {
                    continueButton
                }
                Spacer()
                cancelButton
                saveButton
            }.padding(16)
        }
        .frame(width: 580, height: 560)
        .onAppear { amountFocused = true }
        #else
        NavigationStack {
            Form { fields }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(entry == nil ? "记一笔" : "编辑记录").ledgerInlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                    ToolbarItem(placement: .confirmationAction) { saveButton }
                }
        }
        #endif
    }

    private var cancelButton: some View {
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
    }
    private var saveButton: some View {
        Button("保存") { save(continuing: false) }.fontWeight(.semibold)
            .disabled(draft.amount.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("entry.save").keyboardShortcut(.defaultAction)
    }
    private var continueButton: some View {
        Button("保存并继续") { save(continuing: true) }
            .disabled(draft.amount.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("entry.save.continue")
    }
    @ViewBuilder private var fields: some View {
        Section {
            Picker("类型", selection: $draft.kind) {
                ForEach(EntryKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("entry.kind")
            amountCard
            #if os(iOS)
            if amountFocused {
                Button("完成金额输入") { amountFocused = false }.font(.subheadline).foregroundStyle(kindColor)
            }
            #endif
            if let success { Text(success).foregroundStyle(.teal).accessibilityIdentifier("entry.success") }
        } header: {
            Text("金额与类型")
        } footer: {
            Text("人民币 · 精确到分")
        }
        Section("交易信息") {
            if draft.kind == .refund {
                Picker("退款来源", selection: $historyRefund) {
                    Text("逐笔支出").tag(false); Text("历史消费").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("refund.source")
                if historyRefund {
                    Picker("历史汇总", selection: $draft.originalEntryID) {
                        Text("请选择历史分类").tag(String?.none)
                        ForEach(options.refundSources) { source in
                            Text(source.title).tag(Optional(source.id))
                        }
                    }.accessibilityIdentifier("refund.history")
                    accountPicker("退款到账账户", selection: $draft.accountID)
                    TextField("凭据说明，例如退款单号", text: $draft.refundReference).accessibilityIdentifier("refund.reference")
                    TextField("退款原因", text: $draft.refundReason, axis: .vertical).accessibilityIdentifier("refund.reason")
                    Text("退款须在历史截止日之后，按到账月份冲减原分类。累计退款不超过该历史合计；请按实际凭据核实单笔金额。凭据说明随备份保存。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("原支出", selection: $draft.originalEntryID) {
                        Text("请选择").tag(String?.none)
                        ForEach(options.refundSources) { source in
                            Text(source.title).tag(Optional(source.id))
                        }
                    }
                    Text("退款沿用原支出的分类和账户，累计不能超过原支出。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if draft.kind != .transfer {
                    if entry == nil && !requiresAIReview {
                        let recent = repository.preferences.recentCategories.compactMap { id in options.categories.first { $0.id == id } }
                        if !recent.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(recent) { category in
                                    categoryChip(category)
                                }
                            }
                        }
                    }
                    Picker("分类", selection: $draft.categoryID) {
                        Text("请选择").tag(String?.none)
                        ForEach(options.categories) { category in
                            Label(category.title, systemImage: CategoryGlyph.icon(for: category.name)).tag(Optional(category.id))
                        }
                    }.accessibilityIdentifier("entry.category")
                }
                accountPicker(draft.kind == .transfer ? "转出账户" : "账户", selection: $draft.accountID)
                if draft.kind == .transfer { accountPicker("转入账户", selection: $draft.destinationAccountID) }
                DatePicker("发生日期", selection: $date, in: allowedDates, displayedComponents: .date)
                    .accessibilityIdentifier("entry.date")
                TextField("备注，例如午饭", text: $draft.note, axis: .vertical)
                    .lineLimit(2...4).accessibilityIdentifier("entry.note")
            }
        }
        if entry == nil && !requiresAIReview && (draft.kind == .expense || draft.kind == .income) {
            Section("常用模板") {
                ForEach(repository.preferences.templates) { template in
                    HStack {
                        Button {
                            draft = repository.draft(from: template); date = Date(); error = nil
                        } label: {
                            Label(template.name, systemImage: "bookmark.fill").font(.callout)
                        }
                        Spacer()
                        Button(role: .destructive) { repository.preferences.templates.removeAll { $0.id == template.id } } label: { Image(systemName: "trash") }.accessibilityLabel("删除模板 " + template.name)
                    }
                }
                Button("将当前内容存为模板") {
                    do { try repository.saveTemplate(draft); success = "模板已保存，不包含日期。"; error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
            #if os(iOS)
            Section {
                continueButton
                    .tint(kindColor)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            #endif
        }
        if repository.accounts.isEmpty && draft.kind != .refund {
            Section { Text("可先使用“未指定账户”记账，也可在设置中建立账户。转账需要两个不同账户。").font(.footnote).foregroundStyle(.secondary) }
        }
        if requiresAIReview {
            Section("AI 草稿核实") {
                Text("请核实业务类型、金额、发生日期、分类和账户。缺少日期时暂显示今天；未知账户可明确选择未指定。只有你确认后才保存。").font(.footnote)
                Toggle("已核实上述字段，包括日期与账户", isOn: $aiReviewed).accessibilityIdentifier("ai.draft.confirm")
            }
        }
        if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
    }

    private var amountCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: draft.kind.symbol)
                .font(.title3).foregroundStyle(kindColor)
                .accessibilityHidden(true)
            Text("¥").font(.title2).foregroundStyle(.secondary)
            TextField("0.00", text: $draft.amount).labelsHidden().ledgerKeyboard(.decimalPad)
                .font(.system(.largeTitle, design: .rounded)).fontWeight(.semibold).focused($amountFocused)
                .accessibilityLabel("金额").accessibilityIdentifier("entry.amount")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(kindColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(kindColor.opacity(0.18), lineWidth: 1))
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.15), value: draft.kind)
    }

    private func categoryChip(_ category: EntryEditorOptions.Choice) -> some View {
        let selected = draft.categoryID == category.id
        return Button {
            draft.categoryID = category.id
        } label: {
            HStack(spacing: 4) {
                Image(systemName: CategoryGlyph.icon(for: category.name)).font(.caption2)
                Text(category.name).lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(selected ? kindColor.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? kindColor.opacity(0.45) : .clear, lineWidth: 1))
            .foregroundStyle(selected ? kindColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("常用分类 " + category.name + (selected ? "，已选择" : ""))
    }
    private static let dateRange: ClosedRange<Date> = {
        (try! LedgerDay("1900-01-01")).date()...(try! LedgerDay("2100-12-31")).date()
    }()
    private var allowedDates: ClosedRange<Date> { Self.dateRange }
    private func refreshOptions() {
        options = EntryEditorOptions(repository: repository, kind: draft.kind, entry: entry, historyRefund: historyRefund)
    }
    private func accountPicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("未指定账户").tag(String?.none)
            ForEach(options.accounts) { account in
                Text(account.title).tag(Optional(account.id))
            }
        }
        .accessibilityIdentifier(title == "转入账户" ? "entry.account.destination" : "entry.account.source")
    }
    private func save(continuing: Bool) {
        if requiresAIReview && !aiReviewed { error = "请先核实 AI 草稿的类型、金额、日期、分类与账户。"; return }
        draft.day = LedgerDay(date: date).rawValue
        do {
            try repository.save(draft, editingID: entry?.id)
            if entry == nil { repository.remember(draft) }
            if continuing {
                draft = repository.quickDraft(kind: draft.kind); draft.day = LedgerDay(date: date).rawValue
                success = "已保存，可继续记下一笔。"; error = nil; amountFocused = true
            } else { dismiss() }
        }
        catch { self.error = error.localizedDescription }
    }
}

// Keyword-based SF Symbol suggestions keep offline and never send data; they are
// decoration for chips and picker rows, not a category decision.
enum CategoryGlyph {
    private static let rules: [(keywords: [String], symbol: String)] = [
        (["餐饮", "早", "午", "晚", "夜宵", "外卖", "零食", "饮品", "食"], "fork.knife"),
        (["旅行", "旅游", "机票", "酒店", "度假", "火车", "住宿"], "airplane"),
        (["交通", "出行", "打车", "地铁", "公交", "加油", "停车", "车"], "car"),
        (["购物", "日用", "超市", "服饰", "衣", "数码", "电商"], "bag"),
        (["居住", "房租", "水电", "物业", "房贷", "家"], "house"),
        (["娱乐", "游戏", "电影", "演出", "健身", "运动"], "gamecontroller"),
        (["医疗", "健康", "药", "门诊", "住院"], "cross.case"),
        (["教育", "学习", "书", "课程", "培训"], "book"),
        (["通讯", "话费", "网费", "流量"], "antenna.radiowaves.left.and.right"),
        (["工资", "奖金", "薪酬", "报酬"], "banknote"),
        (["投资", "理财", "利息", "基金", "股"], "chart.line.uptrend.xyaxis"),
        (["宠物"], "pawprint"),
        (["礼", "红包"], "gift")
    ]
    static func icon(for name: String) -> String {
        for rule in rules where rule.keywords.contains(where: name.contains) { return rule.symbol }
        return "tag"
    }
}

// Value snapshots keep SwiftData relationship scans and label formatting out of
// the keystroke/focus update path. Refresh only when the source data or type changes.
struct EntryEditorOptions {
    struct Choice: Identifiable {
        let id: String
        let name: String
        let title: String
    }
    let categories: [Choice]
    let accounts: [Choice]
    let refundSources: [Choice]

    @MainActor init(repository: LedgerRepository, kind: EntryKind, entry: LedgerEntry?, historyRefund: Bool = false) {
        let byID = Dictionary(uniqueKeysWithValues: repository.categories.map { ($0.id, $0) })
        let selectable = Set(repository.selectableCategories(for: kind).map(\.id))
        categories = repository.categories.compactMap { category in
            guard category.kindRaw == kind.rawValue,
                  selectable.contains(category.id) || category.id == entry?.categoryID else { return nil }
            let parent = category.parentID.flatMap { byID[$0]?.name }
            let path = parent.map { $0 + " · " + category.name } ?? category.name
            return Choice(id: category.id, name: category.name, title: path + (category.isArchived ? "（停用）" : ""))
        }
        accounts = repository.accounts.compactMap { account in
            guard !account.isArchived || account.id == entry?.accountID || account.id == entry?.destinationAccountID else { return nil }
            return Choice(id: account.id, name: account.name, title: account.name + (account.isArchived ? "（停用）" : ""))
        }
        if kind != .refund {
            refundSources = []
        } else if historyRefund {
            refundSources = repository.refundableHistories.map { history in
                Choice(id: history.id, name: "", title: "\(byID[history.categoryID]?.name ?? "未分类") · \(history.startDay) 至 \(history.endDay) · \(Money.display(history.amountCents))")
            }
        } else {
            refundSources = repository.entries.filter { $0.kind == .expense }.map { original in
                let category = original.categoryID.flatMap { byID[$0]?.name } ?? "未分类"
                return Choice(id: original.id, name: "", title: "\(original.day) \(category) \(Money.display(original.amountCents)) \(original.note)")
            }
        }
    }
}

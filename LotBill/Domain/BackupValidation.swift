import Foundation

extension LedgerBackup {
    static let maximumBytes = 40 * 1024 * 1024
    var recordCount: Int { accounts.count + categories.count + entries.count + histories.count + batches.count + statements.count + statementItems.count + adjustments.count + audits.count }
    var summary: String { "流水 \(entries.count)；历史 \(histories.count)；账户 \(accounts.count)；分类 \(categories.count)；导入批次 \(batches.count)；对账版本 \(statements.count)；对账项 \(statementItems.count)；调整修订 \(adjustments.count)；审计 \(audits.count)" }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw LedgerError.invalid("备份超过 40 MiB，请缩小账本规模后重试。") }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw LedgerError.invalid("备份不得超过 40 MiB。") }
        struct Header: Decodable { let format: String; let version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == "lotbill-ledger" else { throw LedgerError.invalid("不是有效的 Lot Bill 账本备份。") }
        guard [1, 2].contains(header.version) else { throw LedgerError.invalid("不支持此备份版本（\(header.version)），请使用匹配版本的 App。") }
        guard let result = try? JSONDecoder().decode(Self.self, from: data) else { throw LedgerError.invalid("备份结构损坏或字段不完整。") }
        try result.validate()
        return result
    }
    static func read(url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try decode(data)
    }
    func validate() throws {
        func require(_ condition: Bool, _ detail: String) throws {
            guard condition else { throw LedgerError.invalid("备份校验失败：" + detail) }
        }
        try require(format == "lotbill-ledger" && [1, 2].contains(version), "版本不支持。")
        try require(recordCount <= 100_000, "记录数量超过 100000。")
        let allIDs = accounts.map(\.id) + categories.map(\.id) + entries.map(\.id) + histories.map(\.id) + batches.map(\.id) + statements.map(\.id) + statementItems.map(\.id) + adjustments.map(\.id) + audits.map(\.id)
        try require(allIDs.allSatisfy { !$0.isEmpty && $0.count <= 200 } && Set(allIDs).count == allIDs.count, "ID 为空、过长或重复。")
        let accountIDs = Set(accounts.map(\.id)), categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), batchMap = Dictionary(uniqueKeysWithValues: batches.map { ($0.id, $0) })
        let statementMap = Dictionary(uniqueKeysWithValues: statements.map { ($0.id, $0) }), itemMap = Dictionary(uniqueKeysWithValues: statementItems.map { ($0.id, $0) })
        let historyMap = Dictionary(uniqueKeysWithValues: histories.map { ($0.id, $0) })
        let parents = Set(categories.compactMap(\.parentID))
        func categoryValid(_ id: String?, kind: String) -> Bool {
            guard let id, let category = categoryMap[id] else { return false }
            return category.kindRaw == kind && !parents.contains(id)
        }
        let dates = [createdAt] + entries.flatMap { [$0.createdAt, $0.updatedAt] } + batches.map(\.createdAt) + audits.map(\.createdAt)
        try require(dates.allSatisfy { $0.timeIntervalSince1970.isFinite && (-2_208_988_800...4_133_980_800).contains($0.timeIntervalSince1970) }, "创建或修订时间超出支持范围。")
        try require(Set(accounts.map(\.name)).count == accounts.count, "账户名称重复。")
        try require(Set(categories.map { [$0.kindRaw, $0.parentID ?? "", $0.name] }).count == categories.count, "同级分类名称重复。")
        let seededIDs = ["daily": 11, "clothing": 4, "entertainment": 3, "digital": 3, "car": 6].flatMap { group, count in
            ["expense." + group] + (0..<count).map { "expense.\(group).\($0)" }
        } + ["income.other"]
        try require(Set(seededIDs).isSubset(of: Set(categoryMap.keys)), "内置分类 ID 缺失，无法保证重启后一致。")
        for a in accounts { try require(!a.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && a.name.count <= 40, "账户名称无效。") }
        for c in categories {
            try require(!c.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && c.name.count <= 40 && ["expense", "income"].contains(c.kindRaw), "分类无效。")
            if let parentID = c.parentID {
                let parent = categoryMap[parentID]
                try require(parentID != c.id && parent != nil && parent?.parentID == nil && parent?.kindRaw == c.kindRaw, "分类层级或父级引用无效。")
            }
        }
        var refunded: [String: Int64] = [:]
        for e in entries {
            _ = try LedgerDay(e.day)
            try require(e.currency == "CNY" && e.amountCents > 0 && e.amountCents <= Money.maximum && e.note.count <= 1000 && TimeZone(identifier: e.timeZoneID) != nil, "流水金额、币种、备注或时区无效。")
            try require(e.accountID == nil || accountIDs.contains(e.accountID!), "流水账户不存在。")
            switch e.kindRaw {
            case "expense", "income":
                try require(categoryValid(e.categoryID, kind: e.kindRaw) && e.destinationAccountID == nil && e.originalEntryID == nil, "收支分类或关联无效。")
            case "transfer":
                try require(e.accountID != nil && e.destinationAccountID != nil && accountIDs.contains(e.destinationAccountID!) && e.destinationAccountID != e.accountID && e.categoryID == nil && e.originalEntryID == nil, "转账关联无效。")
            case "refund":
                guard let originalID = e.originalEntryID else { throw LedgerError.invalid("备份退款缺少来源。") }
                if let original = entryMap[originalID] {
                    try require(original.kindRaw == "expense" && e.day >= original.day && e.categoryID == original.categoryID && e.accountID == original.accountID && e.destinationAccountID == nil, "退款来源、分类或日期无效。")
                } else if let history = historyMap[originalID] {
                    try require(version == 2 && history.isActive && history.kindRaw == "expense" && history.batchID != nil && e.day > history.endDay && e.categoryID == history.categoryID && e.destinationAccountID == nil, "历史退款来源或日期无效。")
                    let evidence = audits.filter { $0.kind == "historicalRefund" && $0.ownerID == history.id }.compactMap {
                        try? JSONDecoder().decode(HistoricalRefundEvidence.self, from: Data($0.payload.utf8))
                    }
                    try require(evidence.contains { $0.historyID == history.id && $0.entryID == e.id && $0.amountCents == e.amountCents && $0.day == e.day }, "历史退款缺少匹配的凭据快照。")
                } else { throw LedgerError.invalid("备份退款来源不存在。") }
                refunded[originalID] = try Money.add(refunded[originalID, default: 0], e.amountCents)
            default: throw LedgerError.invalid("备份流水类型未知。")
            }
        }
        for (id, amount) in refunded { try require(amount <= (entryMap[id]?.amountCents ?? historyMap[id]?.amountCents ?? -1), "退款超过原支出。") }
        for b in batches {
            try require(["history", "reconciliation"].contains(b.purpose) && ["committed", "undone"].contains(b.status) && b.mappingVersion == 1 && b.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && b.sourceName.count <= 1024, "导入批次信息无效。")
        }
        var activeRanges: [String: [(String, String)]] = [:]
        for h in histories {
            let period = try LedgerPeriod(start: h.startDay, end: h.endDay)
            guard let precision = PeriodPrecision(rawValue: h.precision) else { throw LedgerError.invalid("备份历史精度未知。") }
            try precision.validate(period)
            try require((categoryValid(h.categoryID, kind: h.kindRaw) || categoryMap[h.categoryID].map { $0.parentID == nil && $0.kindRaw == h.kindRaw } == true) && ["expense", "income"].contains(h.kindRaw) && h.currency == "CNY" && (0...Money.maximum).contains(h.amountCents), "历史金额或分类无效。")
            if let id = h.batchID { try require(batchMap[id]?.purpose == "history" && (!h.isActive || batchMap[id]?.status == "committed"), "历史来源批次无效。") }
            if h.isActive { activeRanges[h.categoryID, default: []].append((h.startDay, h.endDay)) }
        }
        let entryDays = Dictionary(grouping: entries.filter { $0.kindRaw != "transfer" }, by: { $0.categoryID ?? "" }).mapValues { $0.map(\.day).sorted() }
        let children = Dictionary(grouping: categories.filter { $0.parentID != nil }, by: { $0.parentID! }).mapValues { $0.map(\.id) }
        for (category, own) in activeRanges {
            // A first-level summary also covers its children, so check it against each child's history and entries.
            for scope in [category] + (children[category] ?? []) {
                let sorted = (scope == category ? own : own + (activeRanges[scope] ?? [])).sorted { $0.0 < $1.0 }
                for i in sorted.indices where i > 0 { try require(sorted[i - 1].1 < sorted[i].0, "历史期间重叠。") }
                let days = entryDays[scope] ?? []
                var index = 0
                for range in own.sorted(by: { $0.0 < $1.0 }) {
                    while index < days.count && days[index] < range.0 { index += 1 }
                    try require(index >= days.count || days[index] > range.1, "历史与流水重复覆盖。")
                }
            }
        }
        var versions = Set<String>(), activeMonths = Set<String>()
        for s in statements {
            _ = try LedgerDay(s.month + "-01")
            try require(s.scope == "allAccounts" && ["netExpense", "grossExpense"].contains(s.basis) && s.version > 0 && s.version < Int.max && versions.insert("\(s.month):\(s.version)").inserted, "对账范围或版本无效。")
            if s.isActive { try require(activeMonths.insert(s.month).inserted, "同月存在多个有效版本。") }
            if let id = s.batchID { try require(batchMap[id]?.purpose == "reconciliation" && (!s.isActive || batchMap[id]?.status == "committed"), "对账批次引用无效。") }
        }
        var categoryItems = Set<String>()
        for i in statementItems {
            guard let s = statementMap[i.statementID] else { throw LedgerError.invalid("对账项目找不到所属版本。") }
            try require(categoryValid(i.categoryID, kind: "expense") && i.currency == "CNY" && categoryItems.insert(i.statementID + ":" + i.categoryID).inserted, "对账分类或重复项目。")
            if let amount = i.amountCents { try require((-Money.maximum...Money.maximum).contains(amount) && (s.basis == "netExpense" || amount >= 0), "对账金额无效。") }
        }
        var revisions = Set<String>(), activeItems = Set<String>()
        for a in adjustments {
            guard let i = itemMap[a.statementItemID], let s = statementMap[i.statementID] else { throw LedgerError.invalid("调整缺失来源对账项。") }
            try require(a.month == s.month && a.categoryID == i.categoryID && i.amountCents != nil && s.basis == "netExpense" && a.currency == "CNY" && (-Money.maximum...Money.maximum).contains(a.signedCents) && !a.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && a.reason.count <= 1000 && a.revision > 0 && a.revision < Int.max && revisions.insert("\(a.statementItemID):\(a.revision)").inserted, "调整金额、版本或关联无效。")
            if a.isActive { try require(s.isActive && activeItems.insert(a.statementItemID).inserted, "旧版本仍有有效调整或存在重复调整。") }
        }
        let historyByBatch = Dictionary(grouping: histories, by: { $0.batchID ?? "" })
        let importsByOwner = Dictionary(grouping: audits.filter { $0.kind == "import" }, by: \.ownerID)
        for a in audits {
            try require(a.payload.utf8.count <= 4 * 1024 * 1024, "审计内容过大。")
            if a.kind == "historicalRefund" {
                guard version == 2, let history = historyMap[a.ownerID],
                      let evidence = try? JSONDecoder().decode(HistoricalRefundEvidence.self, from: Data(a.payload.utf8)) else { throw LedgerError.invalid("历史退款审计引用无效。") }
                try evidence.validate()
                // Immutable evidence describes the refund at the time, even if the history is later edited.
                // Live refunds are checked against the current category, period and cumulative amount above.
                try require(evidence.historyID == history.id, "历史退款快照无效。")
            } else if a.kind == "historyEdit" {
                guard let history = historyMap[a.ownerID], let edit = try? JSONDecoder().decode(HistoryEdit.self, from: Data(a.payload.utf8)) else { throw LedgerError.invalid("历史编辑快照损坏。") }
                for snapshot in [edit.before, edit.after] {
                    try require(snapshot.id == history.id && categoryMap[snapshot.category]?.kindRaw == snapshot.kind && snapshot.currency == "CNY" && (0...Money.maximum).contains(snapshot.amount), "历史编辑快照无效。")
                    guard let precision = PeriodPrecision(rawValue: snapshot.precision) else { throw LedgerError.invalid("历史编辑期间无效。") }
                    try precision.validate(LedgerPeriod(start: snapshot.start, end: snapshot.end))
                }
            } else {
                try require(["import", "undo", "statement", "adjustment", "review"].contains(a.kind) && (batchMap[a.ownerID] != nil || statementMap[a.ownerID] != nil) && a.payload.utf8.count <= 4 * 1024 * 1024, "审计类型、大小或引用无效。")
            }
            if a.kind == "import" {
                guard let receipt = try? JSONDecoder().decode(ImportReceipt.self, from: Data(a.payload.utf8)), let batch = batchMap[a.ownerID] else { throw LedgerError.invalid("导入来源快照损坏。") }
                try require(receipt.rows.count <= 10_000 && receipt.rows.allSatisfy { (1...10_000).contains($0.row) && ($0.categoryID == nil || categoryMap[$0.categoryID!] != nil) }, "导入行引用无效。")
                if batch.purpose == "history" {
                    let linked = historyByBatch[batch.id] ?? []
                    try require(Set(receipt.history.map(\.id)) == Set(linked.map(\.id)) && receipt.statementID == nil, "历史来源快照引用不完整。")
                } else { try require(receipt.statementID != nil && statementMap[receipt.statementID!]?.batchID == batch.id && receipt.history.isEmpty, "对账来源快照引用不完整。") }
            }
        }
        for batch in batches { try require(importsByOwner[batch.id]?.count == 1, "每个导入批次必须有唯一来源快照。") }
    }
}

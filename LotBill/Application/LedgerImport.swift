import Foundation
import SwiftData
import CryptoKit

extension LedgerRepository {
    func importReceipt(_ batch: ImportBatch) -> ImportReceipt? {
        guard let audit = audits.first(where: { $0.ownerID == batch.id && $0.kind == "import" }) else { return nil }
        return try? JSONDecoder().decode(ImportReceipt.self, from: Data(audit.payload.utf8))
    }
    func preview(file: ImportFile, mapping: ImportMapping, purpose: ImportPurpose) throws -> ImportPreview {
        guard file.sheets.indices.contains(mapping.sheetIndex) else { throw LedgerError.invalid("请选择工作表。") }
        return purpose == .history ? try historyPreview(file: file, mapping: mapping) : try reconciliationPreview(file: file, mapping: mapping)
    }

    private static let totalLabels = ["总计", "合计", "小计", "total", "grand total"]

    /// Preserve second-level annual totals; parent totals are checks when child amounts are supplied.
    private func historyPreview(file: ImportFile, mapping: ImportMapping) throws -> ImportPreview {
        let sheet = file.sheets[mapping.sheetIndex]
        let columns = try mapping.historyColumns()
        guard mapping.firstRow > 0, mapping.firstRow <= mapping.lastRow, mapping.lastRow <= sheet.rows.count,
              mapping.parentColumn >= 0, mapping.categoryColumn >= -1, mapping.amountColumn >= 0,
              mapping.parentColumn < sheet.columnCount, mapping.categoryColumn < sheet.columnCount,
              mapping.amountColumn < sheet.columnCount,
              Set([mapping.parentColumn, mapping.categoryColumn, mapping.amountColumn].filter { $0 >= 0 }).count == (mapping.categoryColumn < 0 ? 2 : 3)
        else { throw LedgerError.invalid("请检查数据行范围和列映射：大类列、二级分类列与年度金额列不能重复，且需在表格范围内。") }
        var issues: [String] = []
        if batches.contains(where: { $0.purpose == ImportPurpose.history.rawValue && $0.digest == file.digest && $0.status == "committed" && (importReceipt($0)?.sheet ?? sheet.name) == sheet.name }) {
            issues.append("此工作表已经导入；请先撤销原批次，或选择更新后的文件。")
        }
        let available = historyCategories(for: .expense)
        var parents = categoryParents
        var proposed: [String: ImportCategory] = [:]
        var rows: [ImportCandidate] = []
        var declaredTotals: [String: [Int64]] = [:]
        for number in mapping.firstRow...mapping.lastRow {
            let parentCell = sheet.cell(row: number, column: mapping.parentColumn, fillMerged: true)
            let childCell = sheet.cell(row: number, column: mapping.categoryColumn)
            let parent = parentCell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let child = childCell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let amountCells = columns.map { sheet.cell(row: number, column: $0.column) }
            if parent.isEmpty && child.isEmpty && amountCells.allSatisfy({ $0.text.isEmpty && $0.error == nil }) { continue }
            let label = [parent, child].filter { !$0.isEmpty }.joined(separator: " · ")
            let isTotal = [parent, child].contains { Self.totalLabels.contains($0.lowercased()) }
            let parentCategory = available.first { $0.parentID == nil && $0.name == parent }
            var categoryID: String?
            var categoryIssue: String?
            var note: String?
            if !isTotal {
                if let override = mapping.categoryOverrides[number], available.contains(where: { $0.id == override }) {
                    categoryID = override
                } else if mapping.categoryOverrides[number] != nil {
                    categoryIssue = "映射分类已不可用，请重新选择。"
                } else if let parentCategory {
                    if child.isEmpty { categoryID = parentCategory.id }
                    else if let existing = categories.first(where: { $0.parentID == parentCategory.id && $0.name == child }) {
                        if available.contains(where: { $0.id == existing.id }) { categoryID = existing.id }
                        else { categoryIssue = "二级分类已停用，请启用或重新映射。" }
                    } else if child.count <= 40 && !entries.contains(where: { $0.categoryID == parentCategory.id }) && !statementItems.contains(where: { $0.categoryID == parentCategory.id }) {
                        let key = parentCategory.id + "|" + child
                        let baseID = "history.category." + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                        var id = baseID, suffix = 1
                        // A previously imported category may have been renamed; never upsert over it.
                        while categories.contains(where: { $0.id == id }) { id = baseID + ".\(suffix)"; suffix += 1 }
                        proposed[id] = ImportCategory(id: id, name: child, parentID: parentCategory.id)
                        parents[id] = parentCategory.id; categoryID = id
                        note = "导入时新增二级分类：" + label
                    } else { categoryIssue = "无法新增二级分类，请在预览中映射到已有分类（名称最多 40 字）。" }
                } else { categoryIssue = "大类未匹配，请指定分类或调整行范围。" }
            }
            for (column, cell) in zip(columns, amountCells) {
                var issue = cell.error ?? childCell.error ?? parentCell.error ?? categoryIssue
                var amount: Int64?
                do { amount = try mapping.amountFormat.parse(cell.text) } catch { issue = error.localizedDescription }
                if isTotal, let amount, ![parent, child].contains("小计") { declaredTotals[column.label, default: []].append(amount) }
                rows.append(ImportCandidate(row: number, sourceCategory: label, categoryID: categoryID, amountCents: amount, formula: cell.formula, issue: issue, isTotal: isTotal, period: column.label, note: note))
            }
        }
        var summaries: [ImportSummaryLine] = [], total: Int64 = 0
        let categoryIDs = Array(Set(rows.filter { !$0.isTotal }.compactMap(\.categoryID))).sorted()
        for column in columns {
            var sum: Int64 = 0
            for categoryID in categoryIDs {
                let indices = rows.indices.filter { !rows[$0].isTotal && rows[$0].period == column.label && rows[$0].categoryID == categoryID }
                let supplied = indices.filter { rows[$0].amountCents != nil }
                var amount: Int64? = supplied.isEmpty ? nil : try supplied.reduce(Int64(0)) { try Money.add($0, rows[$1].amountCents!) }
                var issue: String?, note: String?
                if parents[categoryID] == nil {
                    if supplied.count > 1 {
                        issue = "同一大类出现多行汇总，请检查二级分类列或修正范围。"
                    }
                    let children = rows.indices.filter { !rows[$0].isTotal && rows[$0].period == column.label && rows[$0].categoryID.flatMap { parents[$0] } == categoryID && rows[$0].amountCents != nil }
                    if !children.isEmpty {
                        let childSum = try children.reduce(Int64(0)) { try Money.add($0, rows[$1].amountCents!) }
                        if let amount, amount != childSum { issue = "大类金额与二级分类合计不一致，请核对源文件。" }
                        for i in indices { rows[i].note = "大类金额仅用于核验，按二级分类保存。"; rows[i].issue = rows[i].issue ?? issue }
                        if issue == nil { continue }
                        amount = nil
                    }
                } else if supplied.count > 1 { note = "合并同一二级分类的 \(supplied.count) 行金额。" }
                if let amount {
                    sum = try Money.add(sum, amount)
                    for existing in histories where existing.isActive && LedgerStatistics.categoriesOverlap(existing.categoryID, categoryID, parents: parents) {
                        if column.period.overlaps(try LedgerPeriod(start: existing.startDay, end: existing.endDay)) { issue = "与已有历史期间重叠，请先编辑历史账单或处理原批次。" }
                    }
                    if entries.contains(where: { LedgerStatistics.categoriesOverlap($0.categoryID, categoryID, parents: parents) && $0.kind != .transfer && column.period.contains($0.day) }) { issue = "与此分类现有的每日流水重叠。" }
                    for adjustment in adjustments where adjustment.isActive && LedgerStatistics.categoriesOverlap(adjustment.categoryID, categoryID, parents: parents) {
                        if column.period.overlaps(.month(containing: try LedgerDay(adjustment.month + "-01").date())) { issue = "与有效月度调整重叠。" }
                    }
                }
                summaries.append(ImportSummaryLine(categoryID: categoryID, period: column.label, startDay: column.period.start.rawValue, endDay: column.period.end.rawValue,
                                                   precision: column.precision, amountCents: amount, issue: issue, note: note))
            }
            if (declaredTotals[column.label] ?? []).contains(where: { $0 != sum }) { issues.append("\(column.label) 总计校验不一致：分类金额合计为 \(Money.display(sum))。请修正范围或源文件。") }
            total = try Money.add(total, sum)
        }
        return ImportPreview(file: file, mapping: mapping, purpose: .history, rows: rows, summaries: summaries, issues: issues, total: total, newCategories: proposed.values.sorted { $0.id < $1.id })
    }

    private func reconciliationPreview(file: ImportFile, mapping: ImportMapping) throws -> ImportPreview {
        let sheet = file.sheets[mapping.sheetIndex]
        guard mapping.firstRow > 0, mapping.firstRow <= mapping.lastRow, mapping.lastRow <= sheet.rows.count,
              mapping.parentColumn >= -1, mapping.categoryColumn >= 0, mapping.amountColumn >= 0,
              mapping.categoryColumn < sheet.columnCount, mapping.amountColumn < sheet.columnCount,
              mapping.parentColumn < sheet.columnCount,
              Set([mapping.parentColumn, mapping.categoryColumn, mapping.amountColumn].filter { $0 >= 0 }).count == (mapping.parentColumn < 0 ? 2 : 3)
        else { throw LedgerError.invalid("请检查数据行范围和列映射，各列不能重复。") }
        let period = try LedgerPeriod(start: mapping.startDay, end: mapping.endDay)
        try PeriodPrecision.month.validate(period)
        guard ["netExpense", "grossExpense"].contains(mapping.basis) else {
            throw LedgerError.invalid("对账仅支持完整自然月、全部账户的人民币支出。")
        }
        var issues: [String] = []
        if batches.contains(where: { $0.purpose == ImportPurpose.reconciliation.rawValue && $0.digest == file.digest && $0.status == "committed" }) {
            issues.append("同一用途的原文件已经导入；请先撤销原批次，或选择更新后的文件。")
        }
        var rows: [ImportCandidate] = [], seen = Set<String>(), total: Int64 = 0, declaredTotals: [Int64] = []
        for number in mapping.firstRow...mapping.lastRow {
            let parentCell = sheet.cell(row: number, column: mapping.parentColumn, fillMerged: true)
            let categoryCell = sheet.cell(row: number, column: mapping.categoryColumn)
            let parent = parentCell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let child = categoryCell.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let amountCell = sheet.cell(row: number, column: mapping.amountColumn)
            if parent.isEmpty && child.isEmpty && amountCell.text.isEmpty && amountCell.error == nil { continue }
            let label = [parent, child].filter { !$0.isEmpty }.joined(separator: " · ")
            let isTotal = [parent, child].contains { Self.totalLabels.contains($0.lowercased()) }
            var issue = amountCell.error ?? categoryCell.error ?? parentCell.error
            var amount: Int64?
            do { amount = try mapping.amountFormat.parse(amountCell.text, signed: mapping.basis == "netExpense") }
            catch { issue = error.localizedDescription }
            let matching = selectableCategories(for: .expense).filter { c in
                if let override = mapping.categoryOverrides[number] { return c.id == override }
                return c.name == child && (parent.isEmpty || categories.first(where: { $0.id == c.parentID })?.name == parent)
            }
            let categoryID = matching.count == 1 ? matching.first?.id : nil
            if isTotal {
                if let amount, ![parent, child].contains("小计") { declaredTotals.append(amount) }
            } else {
                if categoryID == nil { issue = issue ?? "分类未唯一匹配，请指定分类或调整行范围。" }
                if let categoryID, let amount {
                    if !seen.insert(categoryID).inserted { issue = "同一分类出现多行，请合并或修正范围。" }
                    total = try Money.add(total, amount)
                }
            }
            rows.append(ImportCandidate(row: number, sourceCategory: label, categoryID: categoryID, amountCents: amount, formula: amountCell.formula, issue: issue, isTotal: isTotal))
        }
        if declaredTotals.contains(where: { $0 != total }) { issues.append("总计校验不一致：分类金额合计为 \(Money.display(total))。请修正范围或源文件。") }
        let supplied = rows.filter { !$0.isTotal && $0.amountCents != nil }
        let same = statements.filter { $0.isActive && $0.month == period.start.month && $0.basis == mapping.basis }.contains { statement in
            let items = statementItems.filter { $0.statementID == statement.id && $0.amountCents != nil }
            return items.count == supplied.count && supplied.allSatisfy { row in items.contains { $0.categoryID == row.categoryID && $0.amountCents == row.amountCents } }
        }
        if same { issues.append("此月已存在相同分类及金额的有效对账依据。") }
        return ImportPreview(file: file, mapping: mapping, purpose: .reconciliation, rows: rows, issues: issues, total: total)
    }

    @discardableResult func importFile(_ preview: ImportPreview) throws -> String {
        // Revalidate against live data; never trust an earlier preview after the ledger changes.
        let current = try self.preview(file: preview.file, mapping: preview.mapping, purpose: preview.purpose)
        guard current.canCommit else { throw LedgerError.invalid("预览存在冲突、错误或没有金额，不能提交。") }
        let batch = ImportBatch(purpose: current.purpose.rawValue, digest: current.file.digest, sourceName: current.file.name)
        var snapshots: [ImportedHistorySnapshot] = []
        var statementID: String?
        try commit {
            context.insert(batch); batch.status = "committed"
            if current.purpose == .history {
                for category in current.newCategories {
                    context.insert(LedgerCategory(id: category.id, name: category.name, parentID: category.parentID, kind: .expense, sortOrder: categories.count + 1))
                }
                for line in current.summaries {
                    guard let amount = line.amountCents else { continue }
                    let history = HistoricalSummary(startDay: line.startDay, endDay: line.endDay, precision: line.precision.rawValue, categoryID: line.categoryID, kind: .expense, amountCents: amount)
                    history.batchID = batch.id; context.insert(history); snapshots.append(ImportedHistorySnapshot(history))
                }
                let covered = try current.summaries.filter { $0.amountCents != nil }.map { try LedgerPeriod(start: $0.startDay, end: $0.endDay) }
                for statement in statements where statement.isActive {
                    let month = LedgerPeriod.month(containing: try LedgerDay(statement.month + "-01").date())
                    if covered.contains(where: month.overlaps) { statement.isReviewed = false }
                }
            } else {
                let values = Dictionary(uniqueKeysWithValues: current.rows.filter { !$0.isTotal && $0.amountCents != nil }.map { ($0.categoryID!, $0.amountCents!) })
                let statement = try insertStatement(month: String(current.mapping.startDay.prefix(7)), values: values, basis: current.mapping.basis, batchID: batch.id)
                statementID = statement.id
            }
            let receipt = ImportReceipt(sheet: current.file.sheets[current.mapping.sheetIndex].name, rows: current.rows, history: snapshots, statementID: statementID)
            context.insert(LedgerAudit(ownerID: batch.id, kind: "import", payload: String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)))
        }
        return batch.id
    }

    func editHistory(id: String, amount: String, categoryID: String, startDay: String, endDay: String, expectedRevision: Int) throws {
        guard expectedRevision == revision else { throw LedgerError.invalid("账本已更新，请重新打开历史账单后编辑。") }
        guard let history = histories.first(where: { $0.id == id && $0.isActive }) else { throw LedgerError.invalid("历史账单已不存在或已撤销。") }
        guard historyCategories(for: EntryKind(rawValue: history.kindRaw) ?? .expense).contains(where: { $0.id == categoryID }) || categoryID == history.categoryID else { throw LedgerError.invalid("请选择有效分类。") }
        let cents = try Money.parse(amount, allowZero: true)
        let period = try LedgerPeriod(start: startDay, end: endDay)
        let precision: PeriodPrecision = period == .year(containing: period.start.date()) ? .year : period == .month(containing: period.start.date()) ? .month : .range
        let parents = categoryParents
        for other in histories where other.id != id && other.isActive && LedgerStatistics.categoriesOverlap(other.categoryID, categoryID, parents: parents) {
            guard !period.overlaps(try LedgerPeriod(start: other.startDay, end: other.endDay)) else { throw LedgerError.invalid("与已有历史账单期间重叠。") }
        }
        guard !entries.contains(where: { $0.kind != .transfer && LedgerStatistics.categoriesOverlap($0.categoryID, categoryID, parents: parents) && period.contains($0.day) }) else { throw LedgerError.invalid("与每日流水重叠，请调整覆盖期间或分类。") }
        for adjustment in adjustments where adjustment.isActive && LedgerStatistics.categoriesOverlap(adjustment.categoryID, categoryID, parents: parents) {
            guard !period.overlaps(.month(containing: try LedgerDay(adjustment.month + "-01").date())) else { throw LedgerError.invalid("与有效月度调整重叠。") }
        }
        let refunds = entries.filter { $0.originalEntryID == id }
        guard try refunds.reduce(Int64(0), { try Money.add($0, $1.amountCents) }) <= cents else { throw LedgerError.invalid("历史金额不能少于已关联的累计退款。") }
        guard refunds.isEmpty || (categoryID == history.categoryID && refunds.allSatisfy { $0.day > endDay }) else { throw LedgerError.invalid("已有退款时不能变更分类，覆盖截止日须早于退款日期。") }
        let before = ImportedHistorySnapshot(history)
        let oldPeriod = try LedgerPeriod(start: history.startDay, end: history.endDay)
        try commit {
            history.amountCents = cents; history.categoryID = categoryID
            history.startDay = startDay; history.endDay = endDay; history.precision = precision.rawValue
            let edit = HistoryEdit(before: before, after: ImportedHistorySnapshot(history))
            context.insert(LedgerAudit(ownerID: history.id, kind: "historyEdit", payload: String(decoding: try JSONEncoder().encode(edit), as: UTF8.self)))
            for statement in statements where statement.isActive {
                let month = LedgerPeriod.month(containing: try LedgerDay(statement.month + "-01").date())
                if month.overlaps(oldPeriod) || month.overlaps(period) { statement.isReviewed = false }
            }
        }
    }

    func undoImpact(_ batch: ImportBatch) throws -> String {
        guard batch.status == "committed", let audit = audits.first(where: { $0.ownerID == batch.id && $0.kind == "import" }) else { throw LedgerError.invalid("此批次不能撤销。") }
        let receipt = try JSONDecoder().decode(ImportReceipt.self, from: Data(audit.payload.utf8))
        if batch.purpose == ImportPurpose.history.rawValue {
            let imported = histories.filter { $0.batchID == batch.id && $0.isActive }
            guard Set(imported.map(ImportedHistorySnapshot.init)) == Set(receipt.history) else { throw LedgerError.invalid("此批次记录已被修改，不能自动撤销。") }
            if entries.contains(where: { entry in imported.contains { $0.id == entry.originalEntryID } }) {
                throw LedgerError.invalid("此历史批次已有消费退款，请先处理关联退款再撤销。")
            }
            let parents = categoryParents
            for history in imported {
                let period = try LedgerPeriod(start: history.startDay, end: history.endDay)
                if statements.contains(where: { statement in
                    guard let day = try? LedgerDay(statement.month + "-01") else { return true }
                    return statementItems.contains { $0.statementID == statement.id && LedgerStatistics.categoriesOverlap($0.categoryID, history.categoryID, parents: parents) && $0.amountCents != nil } && period.overlaps(.month(containing: day.date()))
                }) { throw LedgerError.invalid("此历史批次已被对账引用，不能自动撤销。") }
            }
            return "将停用此批次的 \(imported.count) 项历史汇总；统计随之重算，来源和撤销记录保留。"
        }
        guard let id = receipt.statementID, let statement = statements.first(where: { $0.id == id }), statement.isActive else { throw LedgerError.invalid("此对账版本已被替代，不能撤销。") }
        let ids = Set(statementItems.filter { $0.statementID == id }.map(\.id))
        guard !statement.isReviewed, !adjustments.contains(where: { ids.contains($0.statementItemID) }), !audits.contains(where: { $0.ownerID == id && $0.kind == "review" }) else {
            throw LedgerError.invalid("此对账版本已有调整或核对记录，不能自动撤销。")
        }
        return "将停用该月当前对账依据；旧版本不会自动恢复，流水不受影响。"
    }
    func undoBatch(_ batch: ImportBatch) throws {
        _ = try undoImpact(batch)
        try commit {
            for history in histories where history.batchID == batch.id { history.isActive = false }
            for statement in statements where statement.batchID == batch.id { statement.isActive = false; statement.isReviewed = false }
            batch.status = "undone"
            context.insert(LedgerAudit(ownerID: batch.id, kind: "undo", payload: "用户确认撤销批次"))
        }
    }
    var historyCoverage: String {
        guard let end = histories.filter(\.isActive).map(\.endDay).max() else { return "尚未导入历史汇总。日常记录不代表完整历史覆盖。" }
        guard let start = entries.filter({ $0.day > end }).map(\.day).min() else { return "历史最晚截止 \(end)；此后尚无日常记录。各分类覆盖以导入期间为准。" }
        guard let endDay = try? LedgerDay(end),
              let next = LedgerDay.utcCalendar.date(byAdding: .day, value: 1, to: endDay.date(timeZone: TimeZone(secondsFromGMT: 0)!)) else { return "历史截止日期无效，请检查原始批次。" }
        let expected = LedgerDay(date: next, timeZone: TimeZone(secondsFromGMT: 0)!).rawValue
        return "历史最晚截止 \(end)；后续日常记账始于 \(start)。" + (start > expected ? "中间存在尚未录入的空档。" : "各分类覆盖以导入期间为准。")
    }
}

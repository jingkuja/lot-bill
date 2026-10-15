import Foundation
import ZIPFoundation

enum CSVExportKind: String, CaseIterable, Identifiable {
    case entries, history, adjustments, reconciliation
    var id: String { rawValue }
    var title: String {
        switch self { case .entries: "每日流水"; case .history: "历史期间汇总"; case .adjustments: "月度调整"; case .reconciliation: "对账比较（不计收支）" }
    }
}
enum CSVField {
    case text(String), number(String)
    var escaped: String {
        var value: String
        switch self {
        case .text(let text):
            value = text
            let probe = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\u{FEFF}")))
            if let first = probe.first, "=+-@＝＋－＠".contains(first) { value = "'" + value }
        case .number(let text): value = text
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
struct CSVExport {
    let data: Data
    let count: Int
    let preview: String
}
extension LedgerRepository {
    func csv(kind: CSVExportKind, period: LedgerPeriod, includeInactive: Bool = false, bom: Bool = true) throws -> CSVExport {
        var header: [String] = [], rows: [[CSVField]] = []
        func t(_ value: String?) -> CSVField { .text(value ?? "") }
        func n(_ value: Int64) -> CSVField { .number(Money.decimal(value)) }
        func status(_ active: Bool) -> CSVField { t(active ? "有效" : "已停用") }
        switch kind {
        case .entries:
            header = ["记录类型", "ID", "日期", "业务类型", "金额元", "币种", "分类ID", "分类", "账户ID", "账户", "转入账户ID", "转入账户", "原支出ID", "备注", "时区", "退款来源", "历史批次ID", "退款凭据", "退款原因"]
            rows = entries.filter { period.contains($0.day) }.map { e in
                let evidence = historicalRefundEvidence(for: e)
                let history = histories.first { $0.id == e.originalEntryID }
                return [t("daily"), t(e.id), t(e.day), t(e.kindRaw), n(e.amountCents), t(e.currency), t(e.categoryID), t(categoryPath(e.categoryID)), t(e.accountID), t(accountName(e.accountID)), t(e.destinationAccountID), t(e.destinationAccountID.map { accountName($0) }), t(e.originalEntryID), t(e.note), t(e.timeZoneID), t(e.kind == .refund ? (history == nil ? "逐笔支出" : "历史汇总") : nil), t(history?.batchID), t(evidence?.reference), t(evidence?.reason)]
            }
        case .history:
            header = ["记录类型", "ID", "期间起", "期间止", "精度", "业务类型", "金额元", "币种", "分类ID", "分类", "批次ID", "状态", "覆盖说明"]
            for h in histories.sorted(by: { $0.startDay == $1.startDay ? $0.id < $1.id : $0.startDay < $1.startDay }) where includeInactive || h.isActive {
                let range = try LedgerPeriod(start: h.startDay, end: h.endDay)
                guard range.overlaps(period) else { continue }
                rows.append([t("history"), t(h.id), t(h.startDay), t(h.endDay), t(h.precision), t(h.kindRaw), n(h.amountCents), t(h.currency), t(h.categoryID), t(categoryPath(h.categoryID)), t(h.batchID), status(h.isActive), t(period.contains(range) ? "完整期间" : "跨所选范围，保留原始整段，不能作为期间内合计")])
            }
        case .adjustments:
            header = ["记录类型", "ID", "月份", "期间起", "期间止", "精度", "有符号金额元", "币种", "分类ID", "分类", "来源对账项ID", "修订", "状态", "原因", "覆盖说明"]
            for a in adjustments.sorted(by: { $0.month == $1.month ? $0.revision < $1.revision : $0.month < $1.month }) where includeInactive || a.isActive {
                let range = LedgerPeriod.month(containing: try LedgerDay(a.month + "-01").date())
                guard range.overlaps(period) else { continue }
                rows.append([t("adjustment"), t(a.id), t(a.month), t(range.start.rawValue), t(range.end.rawValue), t("month"), n(a.signedCents), t(a.currency), t(a.categoryID), t(categoryPath(a.categoryID)), t(a.statementItemID), .number(String(a.revision)), status(a.isActive), t(a.reason), t(period.contains(range) ? "完整月份" : "跨所选范围，保留整月调整")])
            }
        case .reconciliation:
            header = ["记录类型", "依据ID", "项目ID", "月份", "版本", "状态", "核对状态", "范围", "口径", "币种", "分类ID", "分类", "依据金额元", "当前账本元", "当前调整元", "当前差额元", "说明"]
            for s in statements where includeInactive || s.isActive {
                let range = LedgerPeriod.month(containing: try LedgerDay(s.month + "-01").date())
                guard range.overlaps(period) else { continue }
                for row in try differences(for: s) {
                    rows.append([t("reconciliation"), t(s.id), t(row.id), t(s.month), .number(String(s.version)), status(s.isActive), t(s.isReviewed ? "已核对，范围及差异见备份审计" : "待核对"), t(s.scope), t(s.basis), t(row.item.currency), t(row.item.categoryID), t(categoryPath(row.item.categoryID)), row.external.map(n) ?? t(nil), n(row.recorded), n(row.adjustment), row.difference.map(n) ?? t(nil), t(row.issue ?? (row.external == nil ? "未提供" : "依据不计入收支；账本值为导出时整月值"))])
                }
            }
        }
        let lines = [header.map { CSVField.text($0).escaped }.joined(separator: ",")] + rows.map { $0.map(\.escaped).joined(separator: ",") }
        let text = (bom ? "\u{FEFF}" : "") + lines.joined(separator: "\r\n") + "\r\n"
        return CSVExport(data: Data(text.utf8), count: rows.count, preview: lines.prefix(21).joined(separator: "\n"))
    }
}

// A snapshot of the same totals shown on the Statistics page, without database IDs or source files.
struct StatisticsExport {
    struct Table {
        let name: String
        let rows: [[CSVField]]
    }
    let tables: [Table]

    func csv() -> Data {
        let empty = CSVField.text("")
        let period = tables[0].rows[1][1]
        var rows: [[CSVField]] = [[.text("统计期间"), .text("分组"), .text("一级分类"), .text("二级分类"), .text("项目"), .text("金额（元）"), .text("说明")]]
        for row in tables[0].rows.dropFirst(2) {
            switch row[1] {
            case .number: rows.append([period, .text("收支汇总"), empty, empty, row[0], row[1], row[2]])
            case .text(let value):
                let note: String
                if case .text(let extra) = row[2] { note = value + "；" + extra } else { note = value }
                rows.append([period, .text("收支汇总"), empty, empty, row[0], empty, .text(note)])
            }
        }
        for row in tables[1].rows.dropFirst() { rows.append([period, .text("一级分类"), row[0], empty, .text("净支出"), row[1], empty]) }
        for row in tables[2].rows.dropFirst() { rows.append([period, .text("二级分类"), row[0], row[1], .text("净支出"), row[2], empty]) }
        let lines = rows.map { $0.map(\.escaped).joined(separator: ",") }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

extension LedgerRepository {
    func statisticsExport(period: LedgerPeriod) throws -> StatisticsExport {
        let total = try LedgerStatistics.calculate(period: period, entries: entries, histories: histories, adjustments: adjustments, parents: categoryParents)
        let incomplete = !total.unsplitPeriods.isEmpty
        let note = incomplete ? "部分历史未按月拆分，金额仅为已知数据，不能视为完整期间合计。" : "按已录入记录统计；转账不计收支，退款和有效调整已计入净支出。"
        func t(_ text: String) -> CSVField { .text(text) }
        func n(_ cents: Int64) -> CSVField { .number(Money.decimal(cents)) }
        var overview: [[CSVField]] = [[t("项目"), t("金额 / 内容"), t("说明")],
            [t("统计期间"), t(period.start.rawValue + " 至 " + period.end.rawValue), t("人民币 CNY，金额单位：元")],
            [t("统计口径"), t(incomplete ? "部分数据未拆分" : "已录入收支"), t(note)]]
        for (label, amount) in [("净支出", total.netExpense), ("收入", total.income), ("收支结余", total.surplus), ("消费", total.consumption), ("退款", total.refunds), ("月度调整", total.adjustment)] {
            overview.append([t((incomplete ? "已知" : "") + label), n(amount), t(label == "收支结余" ? "收入减净支出，不代表账户余额" : "")])
        }
        for range in total.unsplitPeriods { overview.append([t("未拆分历史期间"), t(range), t("未分摊进本期金额")]) }
        let firstRows: [[CSVField]] = [[t("一级分类"), t("净支出（元）")]] + total.byFirstCategory.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { [t(categoryName($0.key)), n($0.value)] }
        let detailRows: [[CSVField]] = [[t("一级分类"), t("二级分类"), t("净支出（元）")]] + total.byCategory.keys.sorted { (categoryParents[$0] ?? $0, $0) < (categoryParents[$1] ?? $1, $1) }.map { id in
            [t(categoryName(categoryParents[id] ?? id)), t(categoryParents[id] == nil ? "大类直接记录（未分二级）" : categoryName(id)), n(total.byCategory[id]!)]
        }
        return StatisticsExport(tables: [.init(name: "收支汇总", rows: overview), .init(name: "一级分类", rows: firstRows), .init(name: "二级分类", rows: detailRows)])
    }
}

extension StatisticsExport {
    /// Standard OOXML, using the app's existing ZIP dependency. Text cells are never formulas.
    func xlsx() throws -> Data {
        func xml(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || (32...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value) }))
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let packageRel = "http://schemas.openxmlformats.org/package/2006/relationships"
        var files: [String: String] = [:]
        files["_rels/.rels"] = "<Relationships xmlns=\"\(packageRel)\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        files["xl/workbook.xml"] = "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rel)\"><sheets>" + tables.enumerated().map { "<sheet name=\"\(xml($0.element.name))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined() + "</sheets></workbook>"
        files["xl/_rels/workbook.xml.rels"] = "<Relationships xmlns=\"\(packageRel)\">" + tables.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined() + "<Relationship Id=\"styles\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>"
        files["[Content_Types].xml"] = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>" + tables.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined() + "</Types>"
        files["xl/styles.xml"] = """
        <styleSheet xmlns="\(ns)"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF087F8C"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
        for (index, table) in tables.enumerated() {
            let rows = table.rows.enumerated().map { rowIndex, fields in
                let cells = fields.enumerated().map { col, field in
                    let address = TabularFile.columnName(col) + String(rowIndex + 1)
                    switch field {
                    case .text(let value): return "<c r=\"\(address)\" s=\"\(rowIndex == 0 ? 2 : 0)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
                    case .number(let value): return "<c r=\"\(address)\" s=\"1\"><v>\(value)</v></c>"
                    }
                }.joined()
                return "<row r=\"\(rowIndex + 1)\" ht=\"\(index == 0 ? 44 : 26)\" customHeight=\"1\">\(cells)</row>"
            }.joined()
            files["xl/worksheets/sheet\(index + 1).xml"] = "<worksheet xmlns=\"\(ns)\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols><col min=\"1\" max=\"1\" width=\"28\" customWidth=\"1\"/><col min=\"2\" max=\"2\" width=\"34\" customWidth=\"1\"/><col min=\"3\" max=\"3\" width=\"\(index == 0 ? 64 : 24)\" customWidth=\"1\"/></cols><sheetData>\(rows)</sheetData></worksheet>"
        }
        let archive = try Archive(accessMode: .create)
        for name in files.keys.sorted() {
            let data = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + files[name]!).utf8)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, count in
                data.subdata(in: Int(offset)..<min(Int(offset) + count, data.count))
            }
        }
        guard let data = archive.data else { throw LedgerError.invalid("无法生成 Excel 文件。") }
        return data
    }
}

import Foundation
import CryptoKit
import CoreXLSX
import ZIPFoundation

struct ImportCell: Sendable {
    var text: String = ""
    var formula = false
    var error: String?
}
struct ImportSheet: Sendable, Identifiable {
    var id: Int
    var name: String
    var rows: [[ImportCell]]
    var merges: [String] = []
    func cell(row: Int, column: Int, fillMerged: Bool = false) -> ImportCell {
        guard row > 0, column >= 0 else { return ImportCell() }
        if fillMerged {
            for merge in merges {
                let ends = merge.split(separator: ":").compactMap { TabularFile.coordinate(String($0)) }
                if ends.count == 2, ends[0].column == column, ends[1].column == column,
                   (ends[0].row...ends[1].row).contains(row) {
                    return cell(row: ends[0].row, column: column)
                }
            }
        }
        guard rows.indices.contains(row - 1), rows[row - 1].indices.contains(column) else { return ImportCell() }
        return rows[row - 1][column]
    }
    var columnCount: Int { rows.map(\.count).max() ?? 0 }
}
struct ImportFile: Sendable {
    let name: String
    let digest: String
    let sheets: [ImportSheet]
}

enum TabularFile {
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumRows = 10_000
    static let maximumColumns = 256
    static func read(url: URL) throws -> ImportFile {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw LedgerError.invalid("文件不得超过 10 MB。") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try parse(data: data, name: url.lastPathComponent)
    }
    static func parse(data: Data, name: String) throws -> ImportFile {
        guard data.count <= maximumBytes else { throw LedgerError.invalid("文件不得超过 10 MB。") }
        let sheets: [ImportSheet]
        switch (name as NSString).pathExtension.lowercased() {
        case "csv": sheets = [try csv(data)]
        case "xlsx": sheets = try xlsx(data)
        default: throw LedgerError.invalid("请选择 UTF-8 CSV 或 XLSX 文件，不支持 XLS。")
        }
        return ImportFile(name: name, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), sheets: sheets)
    }
    static func csv(_ data: Data) throws -> ImportSheet {
        guard var text = String(data: data, encoding: .utf8) else { throw LedgerError.invalid("CSV 必须使用 UTF-8 编码。") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var rows: [[ImportCell]] = [], row: [ImportCell] = [], field = ""
        var quoted = false, closed = false, atStart = true
        let chars = Array(text); var i = 0
        func finishField() throws {
            guard row.count < maximumColumns, field.utf8.count <= 32_768 else { throw LedgerError.invalid("CSV 列数或单元格长度超出限制。") }
            row.append(ImportCell(text: field)); field = ""; closed = false; atStart = true
        }
        func finishRow() throws {
            try finishField()
            guard rows.count < maximumRows else { throw LedgerError.invalid("最多支持 10000 行。") }
            rows.append(row); row = []
        }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append(c); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," { try finishField() }
            else if c == "\n" { try finishRow() }
            else if c == "\"", atStart { quoted = true; atStart = false }
            else {
                guard !closed, c != "\"" else { throw LedgerError.invalid("CSV 引号格式错误。") }
                field.append(c); atStart = false
            }
            guard field.utf8.count <= 32_768 else { throw LedgerError.invalid("单元格过长。") }
            i += 1
        }
        guard !quoted else { throw LedgerError.invalid("CSV 引号未闭合。") }
        if !row.isEmpty || !field.isEmpty || closed { try finishRow() }
        guard !rows.isEmpty else { throw LedgerError.invalid("文件为空。") }
        return ImportSheet(id: 0, name: "CSV", rows: rows)
    }
    static func coordinate(_ reference: String) -> (row: Int, column: Int)? {
        let chars = reference.uppercased().unicodeScalars
        var column = 0, digits = "", readingDigits = false
        for c in chars {
            if (65...90).contains(c.value), !readingDigits {
                column = column * 26 + Int(c.value - 64)
                if column > maximumColumns { return nil }
            } else if (48...57).contains(c.value) { readingDigits = true; digits.append(Character(c)) }
            else { return nil }
        }
        guard column > 0, let row = Int(digits), (1...maximumRows).contains(row) else { return nil }
        return (row, column - 1)
    }
    static func columnName(_ index: Int) -> String {
        var value = index + 1, result = ""
        while value > 0 { value -= 1; result = String(UnicodeScalar(65 + value % 26)!) + result; value /= 26 }
        return result
    }
    private static func xlsx(_ data: Data) throws -> [ImportSheet] {
        let archive = try Archive(data: data, accessMode: .read)
        var count = 0, total: UInt64 = 0, paths = Set<String>()
        for entry in archive {
            count += 1; total += UInt64(entry.uncompressedSize)
            guard count <= 1024, total <= 40 * 1024 * 1024, entry.uncompressedSize <= 16 * 1024 * 1024,
                  entry.type != .symlink, !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains(".."),
                  paths.insert(entry.path).inserted else { throw LedgerError.invalid("压缩包内容或解压大小超出安全限制。") }
            // Verify actual decompressed byte count and CRC before handing XML to the decoder.
            var bytes = Data()
            let crc = try archive.extract(entry, bufferSize: 32_768) { chunk in
                guard bytes.count + chunk.count <= 16 * 1024 * 1024 else { throw LedgerError.invalid("解压内容过大。") }
                bytes.append(chunk)
            }
            guard bytes.count == entry.uncompressedSize, crc == entry.checksum else { throw LedgerError.invalid("压缩包校验失败。") }
            if entry.path.lowercased().hasSuffix(".xml") || entry.path.lowercased().hasSuffix(".rels") {
                guard let xml = String(data: bytes, encoding: .utf8),
                      !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else {
                    throw LedgerError.invalid("仅接受不含 DTD/实体声明的 UTF-8 工作簿。")
                }
            }
        }
        let file = try XLSXFile(data: data, bufferSize: 32_768)
        let shared = paths.contains("xl/sharedStrings.xml") ? try file.parseSharedStrings() : nil
        var result: [ImportSheet] = []
        for workbook in try file.parseWorkbooks() {
            let identifiers = workbook.sheets.items.map(\.relationship)
            guard Set(identifiers).count == identifiers.count else { throw LedgerError.invalid("工作表关系 ID 重复。") }
            for (name, path) in try file.parseWorksheetPathsAndNames(workbook: workbook) {
                guard result.count < 32 else { throw LedgerError.invalid("最多支持 32 个工作表。") }
                let worksheet = try file.parseWorksheet(at: path)
                var rows: [[ImportCell]] = []
                var rowIDs = Set<UInt>(), cellIDs = Set<String>()
                for row in worksheet.data?.rows ?? [] {
                    guard row.reference > 0, row.reference <= maximumRows, rowIDs.insert(row.reference).inserted else { throw LedgerError.invalid("工作表行号重复或超出 10000 行。") }
                    while rows.count < Int(row.reference) { rows.append([]) }
                    for cell in row.cells {
                        guard let coord = coordinate(cell.reference.description), coord.row == row.reference,
                              cellIDs.insert(cell.reference.description).inserted else {
                            throw LedgerError.invalid("工作表单元格重复、行号不一致或超出 10000 行 / 256 列范围。")
                        }
                        while rows[coord.row - 1].count <= coord.column { rows[coord.row - 1].append(ImportCell()) }
                        var value = cell.value ?? cell.inlineString?.text ?? ""
                        var error: String?
                        if cell.type == .sharedString {
                            if let index = Int(value), let shared, shared.items.indices.contains(index) {
                                let item = shared.items[index]
                                value = item.text ?? item.richText.compactMap(\.text).joined()
                            } else { error = "共享字符串索引无效。" }
                        }
                        if cell.type == .error { error = "Excel 错误值，请提供数值版本。" }
                        if cell.formula != nil && (cell.value == nil || cell.value == "") { error = "公式没有缓存值，请在 Excel 中计算并另存或改为数值。" }
                        if cell.type == .bool || cell.type == .date { error = "此单元格不是金额或分类文本。" }
                        guard value.utf8.count <= 32_768 else { throw LedgerError.invalid("单元格过长。") }
                        rows[coord.row - 1][coord.column] = ImportCell(text: value, formula: cell.formula != nil, error: error)
                    }
                }
                let merges = worksheet.mergeCells?.items.map(\.reference) ?? []
                guard merges.count <= maximumRows, merges.allSatisfy({ ref in
                    let ends = ref.split(separator: ":").compactMap { coordinate(String($0)) }
                    return ends.count == 2 && ends[0].row <= ends[1].row && ends[0].column <= ends[1].column
                }) else { throw LedgerError.invalid("合并单元格范围无效。") }
                result.append(ImportSheet(id: result.count, name: name ?? "工作表 \(result.count + 1)", rows: rows, merges: merges))
            }
        }
        guard !result.isEmpty else { throw LedgerError.invalid("工作簿没有工作表。") }
        return result
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct LedgerFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, UTType(filenameExtension: "xlsx") ?? .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct CSVExportView: View {
    let repository: LedgerRepository
    @State private var kind: CSVExportKind = .entries
    @State private var start = LedgerPeriod.month(containing: Date()).start.rawValue
    @State private var end = LedgerPeriod.month(containing: Date()).end.rawValue
    @State private var inactive = false
    @State private var bom = true
    @State private var result: CSVExport?
    @State private var document: LedgerFileDocument?
    @State private var exporting = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("导出范围") {
                Picker("数据类型", selection: $kind) { ForEach(CSVExportKind.allCases) { Text($0.title).tag($0) } }
                TextField("开始 YYYY-MM-DD", text: $start).accessibilityIdentifier("export.start")
                TextField("结束 YYYY-MM-DD", text: $end).accessibilityIdentifier("export.end")
                Toggle("包括停用记录和历史版本", isOn: $inactive)
                Toggle("UTF-8 BOM（表格软件兼容）", isOn: $bom)
                Text("CSV 是明文文件。历史及调整按原期间导出，跨范围记录会标注；对账比较不计入支出。文本公式字符会加单引号保护。").font(.footnote).foregroundStyle(.secondary)
                Button("预览 CSV") {
                    do { result = try repository.csv(kind: kind, period: LedgerPeriod(start: start, end: end), includeInactive: inactive, bom: bom); message = nil }
                    catch { message = error.localizedDescription }
                }.accessibilityIdentifier("export.preview")
            }
            if let result {
                Section("\(result.count) 条记录 · 最多预览 20 条") {
                    ScrollView(.horizontal) { Text(result.preview).font(.caption.monospaced()).textSelection(.enabled) }
                    Button("选择位置并导出") { document = LedgerFileDocument(data: result.data); exporting = true }.accessibilityIdentifier("export.save")
                }
            }
            if let message { Text(message).font(.footnote) }
        }.navigationTitle("CSV 导出").scrollDismissesKeyboard(.interactively)
            .onChange(of: kind) { _, _ in result = nil }.onChange(of: start) { _, _ in result = nil }.onChange(of: end) { _, _ in result = nil }
            .onChange(of: inactive) { _, _ in result = nil }.onChange(of: bom) { _, _ in result = nil }
            .onChange(of: repository.revision) { _, _ in result = nil }
            .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "LotBill-\(kind.rawValue)-\(start)-\(end)") { outcome in
                switch outcome { case .success: message = "文件已导出。"; case .failure: message = "导出未完成，账本没有改变。" }
            }
    }
}
struct RestorePreview: Identifiable {
    let id = UUID()
    let backup: LedgerBackup
    let revision: Int
    let source: String
}
struct BackupRestoreView: View {
    let repository: LedgerRepository
    @State private var document: LedgerFileDocument?
    @State private var export = false
    @State private var picking = false
    @State private var busy = false
    @State private var pending: RestorePreview?
    @State private var confirm = false
    @State private var message: String?
    @State private var points: [URL] = []
    @State private var exportedSnapshot: LedgerBackup?
    @State private var rehearsalMessage: String?
    var body: some View {
        Form {
            Section("备份状态") {
                if let stamp = repository.preferences.backupStamp {
                    LabeledContent("最近成功导出", value: stamp.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("快照生成于 \(stamp.snapshotAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    if let changes = try? repository.preferences.changes(in: LedgerBackup(repository: repository)) {
                        Text("相对备份：新增 \(changes.added)、修改 \(changes.changed)、删除 \(changes.removed) 条记录")
                            .accessibilityIdentifier("backup.changes")
                        Text("包含流水、分类、历史和审计；统计当前记录与备份的差异。").font(.caption).foregroundStyle(.secondary)
                    }
                } else { Text("尚未成功导出完整备份").accessibilityIdentifier("backup.never") }
                Picker("应用内备份提醒", selection: Binding(get: { repository.preferences.reminderDays }, set: { repository.preferences.reminderDays = $0 })) {
                    Text("每 7 天").tag(7); Text("每 30 天").tag(30); Text("关闭").tag(0)
                }
                if repository.preferences.backupDue() { Text("建议现在导出一份完整备份。").foregroundStyle(.orange) }
            }
            Section("完整备份") {
                Text("包含完整账本、稳定 ID、来源和核对审计；不含 API Key、AI 服务配置与发送授权。备份是明文，请选择你信任的存储位置。").font(.footnote)
                Text("当前：\(LedgerBackup(repository: repository).summary)").font(.caption)
                Button("生成并导出完整备份") { createBackup() }.accessibilityIdentifier("backup.export")
            }
            Section("整体恢复") {
                Text("恢复会替换全部账本记录。读取文件后先校验并预览；确认时自动保存当前账本恢复点，失败则保留原账本。AI 配置和密钥保持本机当前设置。").font(.footnote)
                Button("选择备份文件") { picking = true }.accessibilityIdentifier("backup.import")
                if let pending {
                    Text("来源：\(pending.source)").font(.caption)
                    Text("备份时间：\(pending.backup.createdAt.formatted())").font(.caption)
                    Text(pending.backup.summary).accessibilityIdentifier("backup.preview.summary")
                    Button("恢复演练（不替换当前账本）") {
                        do { try repository.rehearseRestore(pending.backup); rehearsalMessage = "演练通过：隔离账本已恢复，全部记录与所选备份一致。当前账本未改变。" }
                        catch { rehearsalMessage = error.localizedDescription }
                    }.accessibilityIdentifier("backup.rehearse")
                    Button("确认整体恢复", role: .destructive) { confirm = true }.accessibilityIdentifier("backup.restore")
                    Button("取消恢复预览") { self.pending = nil }
                }
            }
            Section("恢复演练") {
                Text("选择备份文件后可先演练：在独立账本中恢复并核对全部记录，不替换当前账本。").font(.footnote)
                if let date = repository.preferences.rehearsedAt { Text("最近通过：" + date.formatted()).font(.caption) }
                if let rehearsalMessage { Text(rehearsalMessage).accessibilityIdentifier("backup.rehearsal.result") }
            }
            if !points.isEmpty {
                Section("本机恢复点") {
                    ForEach(points, id: \.path) { url in Button(url.lastPathComponent) { load(url) }.font(.caption) }
                    Text("恢复点仅在本机应用存储内，卸载 App 会丢失；可读取后再次导出完整备份。").font(.caption)
                }
            }
            if busy { ProgressView("处理中…") }
            if let message { Text(message).font(.footnote).accessibilityIdentifier("backup.message") }
        }.navigationTitle("备份与恢复").disabled(busy)
            .task {
                refreshPoints()
                #if DEBUG
                if LedgerStore.scope != "main", ProcessInfo.processInfo.arguments.contains("--backup-ui-fixture"), pending == nil {
                    do {
                        let backup = ProcessInfo.processInfo.arguments.contains("--m7-restore-fixture")
                            ? try LedgerBackup.read(url: M7Acceptance.restoreFixtureURL()) : try repository.backup()
                        pending = RestorePreview(backup: backup, revision: repository.revision, source: "合成 UI 备份（独立测试账本）")
                    }
                    catch { message = error.localizedDescription }
                }
                #endif
            }
            .fileExporter(isPresented: $export, document: document, contentType: .json, defaultFilename: "LotBill-Backup-\(LedgerDay(date: Date()).rawValue)") { result in
                switch result {
                case .success:
                    do {
                        if let exportedSnapshot { try repository.preferences.recordExport(exportedSnapshot) }
                        message = "备份已导出。请选择应用之外的独立位置长期保存。"
                    } catch { message = "备份文件已导出，但本机备份状态保存失败：" + error.localizedDescription }
                case .failure: message = "导出未完成，备份状态没有更新。"
                }
                exportedSnapshot = nil
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): load(url); case .failure: message = "未能读取所选文件。" }
            }
            .confirmationDialog("替换当前全部账本？", isPresented: $confirm, titleVisibility: .visible) {
                Button("建立恢复点并替换账本", role: .destructive) {
                    guard let pending else { return }
                    do {
                        let recovery = try repository.restore(pending.backup, expectedRevision: pending.revision)
                        self.pending = nil; message = "恢复成功。原账本恢复点：\(recovery.lastPathComponent)"; refreshPoints()
                    } catch { message = error.localizedDescription }
                }
            } message: { Text("此操作不合并账本。当前数据会先保存为本机恢复点，备份中的全部记录将成为当前账本。") }
    }
    private func createBackup() {
        do {
            let backup = try repository.backup(); busy = true
            Task {
                do {
                    document = LedgerFileDocument(data: try await Task.detached { try backup.encoded() }.value)
                    exportedSnapshot = backup; export = true
                }
                catch { message = error.localizedDescription }
                busy = false
            }
        } catch { message = error.localizedDescription }
    }
    private func load(_ url: URL) {
        busy = true; pending = nil; message = nil; rehearsalMessage = nil
        Task {
            do { let backup = try await Task.detached { try LedgerBackup.read(url: url) }.value; pending = RestorePreview(backup: backup, revision: repository.revision, source: url.lastPathComponent) }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func refreshPoints() {
        do { points = try FileManager.default.contentsOfDirectory(at: LedgerRepository.recoveryDirectory(), includingPropertiesForKeys: [.creationDateKey]).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent } }
        catch { message = "无法读取本机恢复点。" }
    }
}

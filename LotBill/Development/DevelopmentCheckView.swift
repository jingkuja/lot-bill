import SwiftUI
import SwiftData

struct DevelopmentCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DevelopmentRecord.createdAt, order: .reverse)
    private var records: [DevelopmentRecord]
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("保存一条测试文字，重新启动 App 后检查记录是否仍在。")
                        .foregroundStyle(.secondary)
                    TextField("测试文字", text: $text)
                        .accessibilityIdentifier("development.record.text")
                    Button("保存测试记录", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("development.record.save")
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                } header: {
                    Text("本地存储验证")
                } footer: {
                    Text("此页面仅用于开发环境验收，请勿输入真实账单。")
                }
                Section("已保存记录") {
                    if records.isEmpty {
                        Text("暂无测试记录").foregroundStyle(.secondary)
                    }
                    ForEach(records) { record in
                        Text(record.text)
                    }
                }
            }
            .navigationTitle("Lot Bill")
        }
    }

    private func save() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let record = DevelopmentRecord(text: value)
        modelContext.insert(record)
        do {
            try modelContext.save()
            text = ""
            errorMessage = nil
        } catch {
            modelContext.rollback()
            errorMessage = "保存失败，请重试。输入内容已保留。"
        }
    }
}


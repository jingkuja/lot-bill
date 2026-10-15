import XCTest
import SwiftData
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LotBill

// Deterministic in-memory JPEG so image tests never touch files or the network.
enum SyntheticImage {
    static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.85, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for index in 0..<24 { context.fill(CGRect(x: index * width / 48, y: 0, width: max(1, width / 96), height: height)) }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    static func pixelSize(of data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}

private final class HTTPStubState: @unchecked Sendable {
    let lock = NSLock()
    var results: [Result<(Int, Data), URLError>] = []
    var requests: [URLRequest] = []
    var hold = false
    func reset(_ responses: [Result<(Int, Data), URLError>], hold: Bool = false) {
        lock.lock(); defer { lock.unlock() }; results = responses; requests = []; self.hold = hold
    }
    func take(_ request: URLRequest) -> Result<(Int, Data), URLError>? {
        lock.lock(); defer { lock.unlock() }; requests.append(request)
        if hold { return nil }
        return results.isEmpty ? .failure(URLError(.badServerResponse)) : results.removeFirst()
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}
private final class HTTPStub: URLProtocol, @unchecked Sendable {
    static let state = HTTPStubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let result = Self.state.take(request) else { return }
        switch result {
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .success(let (status, data)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class LLMTransportTests: XCTestCase {
    private var config: LLMConfiguration { LLMConfiguration(name: "Synthetic", baseURL: "https://example.invalid/v1", model: "test-model", timeout: 5) }
    private var provider: ChatCompletionsProvider { ChatCompletionsProvider(configurationFactory: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [HTTPStub.self]; return c }) }
    private var response: Data { Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"OK"}}]}"#.utf8) }
    func testRequestProtocolSecretsAndInvalidEndpoints() throws {
        let request = try ChatCompletionsProvider.request(configuration: config, key: "synthetic-key", messages: [LLMMessage(role: "user", content: "test")], json: true)
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 1024); XCTAssertNil(body["tools"])
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("synthetic-key"))
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com?key=secret", "https://example.com#fragment", "file:///etc/passwd"] {
            var invalid = config; invalid.baseURL = url; XCTAssertThrowsError(try invalid.endpoint())
        }
        var legacy = config; legacy.legacyTokenLimit = true; legacy.jsonMode = false
        let oldRequest = try ChatCompletionsProvider.request(configuration: legacy, key: nil, messages: [], json: true)
        let old = try XCTUnwrap(JSONSerialization.jsonObject(with: oldRequest.httpBody!) as? [String: Any])
        XCTAssertNotNil(old["max_tokens"]); XCTAssertNil(old["response_format"])
        XCTAssertThrowsError(try ChatCompletionsProvider.request(configuration: config, key: "bad\nkey", messages: [], json: false))
    }
    func testHTTPRefusalTruncationInvalidJSONAndLimits() throws {
        XCTAssertEqual(try ChatCompletionsProvider.decode(response, status: 200), "OK")
        for status in [301, 401, 403, 429, 500] { XCTAssertThrowsError(try ChatCompletionsProvider.decode(Data("secret server diagnostics".utf8), status: status)) { XCTAssertFalse($0.localizedDescription.contains("secret")) } }
        for raw in [#"{"choices":[]}"#, #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#, #"{"choices":[{"finish_reason":"stop","message":{"refusal":"no","content":"x"}}]}"#, "not json"] { XCTAssertThrowsError(try ChatCompletionsProvider.decode(Data(raw.utf8), status: 200)) }
        XCTAssertThrowsError(try ChatCompletionsProvider.decode(Data(repeating: 65, count: 262145), status: 200))
    }
    func testSuccessfulRequestRetryAndOfflineFailures() async throws {
        HTTPStub.state.reset([.success((429, Data())), .success((200, response))])
        var retry = config; retry.retries = 1
        let output = try await provider.complete(configuration: retry, key: nil, messages: [LLMMessage(role: "user", content: "synthetic")], json: false)
        XCTAssertEqual(output, "OK"); XCTAssertEqual(HTTPStub.state.count(), 2)
        for code in [URLError.Code.timedOut, .notConnectedToInternet] {
            HTTPStub.state.reset([.failure(URLError(code))])
            do { _ = try await provider.complete(configuration: config, key: nil, messages: [], json: false); XCTFail("Expected failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains(code == .timedOut ? "超时" : "网络")) }
        }
    }
    func testCancellationInFlight() async throws {
        HTTPStub.state.reset([], hold: true)
        let service = provider, configuration = config
        let task = Task { try await service.complete(configuration: configuration, key: nil, messages: [], json: false) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRedirectDelegateNeverForwardsCredentials() {
        let request = URLRequest(url: URL(string: "https://other.invalid")!)
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        NoRedirectDelegate().urlSession(session, task: session.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { redirected in XCTAssertNil(redirected) }
    }
    func testImageMessageProtocolAndRequestLimits() throws {
        let image = BillImage(jpeg: Data(repeating: 7, count: 512), pixelWidth: 64, pixelHeight: 64)
        let request = try ChatCompletionsProvider.request(configuration: config, key: "synthetic-key",
                                                          messages: [LLMMessage(role: "user", content: "识别截图", images: [image.dataURL])], json: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "text"); XCTAssertEqual(content[0]["text"] as? String, "识别截图")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        XCTAssertTrue(((content[1]["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        let textRequest = try ChatCompletionsProvider.request(configuration: config, key: nil, messages: [LLMMessage(role: "user", content: "test")], json: true)
        let textBody = try XCTUnwrap(JSONSerialization.jsonObject(with: textRequest.httpBody!) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(textBody["messages"] as? [[String: Any]])[0]["content"] as? String, "test")
        let large = String(repeating: "A", count: 200 * 1024)
        XCTAssertThrowsError(try ChatCompletionsProvider.request(configuration: config, key: nil, messages: [LLMMessage(role: "user", content: large)], json: false))
        XCTAssertNoThrow(try ChatCompletionsProvider.request(configuration: config, key: nil,
                                                             messages: [LLMMessage(role: "user", content: "截图", images: ["data:image/jpeg;base64," + large])], json: true))
        XCTAssertThrowsError(try ChatCompletionsProvider.request(configuration: config, key: nil,
                                                                 messages: [LLMMessage(role: "user", content: "x", images: ["javascript:alert(1)"])], json: true))
    }
}

final class BillImageTests: XCTestCase {
    func testLocalFileReadAndInvalidOrOversizedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("账单.jpeg")
        try SyntheticImage.jpeg(width: 320, height: 640).write(to: file)
        let bill = try BillImage.read(url: file)
        XCTAssertEqual(bill.pixelWidth, 320)
        XCTAssertEqual(bill.pixelHeight, 640)
        try Data("invalid image".utf8).write(to: file)
        XCTAssertThrowsError(try BillImage.read(url: file))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(BillImage.maximumSourceBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try BillImage.read(url: file)) { XCTAssertTrue($0.localizedDescription.contains("32 MiB")) }
        XCTAssertThrowsError(try BillImage.read(url: folder.appendingPathComponent("missing.png")))
    }

    func testPreparationDownscalesStripsMetadataAndRejectsNonImages() throws {
        let bill = try BillImage.prepare(try SyntheticImage.jpeg(width: 3000, height: 2000))
        XCTAssertLessThanOrEqual(max(bill.pixelWidth, bill.pixelHeight), BillImage.maximumPixelSize)
        XCTAssertTrue(bill.dataURL.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertLessThanOrEqual(bill.transferredBytes, BillImage.maximumTransferBytes)
        let decoded = SyntheticImage.pixelSize(of: bill.jpeg)
        XCTAssertEqual(max(decoded.width, decoded.height), max(bill.pixelWidth, bill.pixelHeight))
        guard let source = CGImageSourceCreateWithData(bill.jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return XCTFail("压缩后的截图应可解码")
        }
        // Re-encoding drops source metadata; ImageIO may emit a minimal boilerplate
        // EXIF header, so the privacy assertion is on location data being absent.
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertThrowsError(try BillImage.prepare(Data("not an image".utf8)))
        XCTAssertThrowsError(try BillImage.prepare(Data(repeating: 0, count: BillImage.maximumSourceBytes + 1)))
    }
}

@MainActor final class AIDraftAndSettingsTests: XCTestCase {
    func testStrictOutputAndUnknownFieldsRemainUnconfirmed() throws {
        let r = try LedgerRepository(container: LedgerStore.container(inMemory: true))
        let response = try AICandidate.decode(#"{"kind":"expense","amount":"1.234","day":"2026-02-30","categoryID":"invented","accountID":"unknown","note":"=do not execute"}"#)
        let result = AIAssistance.candidate(response, repository: r, originalText: "午饭")
        XCTAssertEqual(result.draft.amount, ""); XCTAssertEqual(result.draft.day, ""); XCTAssertNil(result.draft.accountID)
        XCTAssertEqual(result.draft.categoryID, "expense.daily.2"); XCTAssertGreaterThanOrEqual(result.warnings.count, 4)
        XCTAssertTrue(r.entries.isEmpty)
        for invalid in [#"{"amount":35}"#, #"{"amount":"35","execute":"delete_all"}"#, "```json\n{}\n```", "{}", "[]"] { XCTAssertThrowsError(try AICandidate.decode(invalid)) }
        let valid = AIAssistance.candidate(try AICandidate.decode(#"{"kind":"income","amount":"100.25","day":"2026-09-01","categoryID":"income.other","accountID":null}"#), repository: r, originalText: "收入")
        XCTAssertEqual(valid.draft.amount, "100.25"); XCTAssertEqual(valid.draft.kind, .income)
        XCTAssertTrue(r.entries.isEmpty)
    }
    func testPromptMinimizationAndDeterministicReport() throws {
        let r = try LedgerRepository(container: LedgerStore.container(inMemory: true))
        try r.save(EntryDraft(amount: "1200", day: "2026-09-01", categoryID: "expense.daily.2", note: "DO_NOT_SEND_PRIVATE_HISTORY"))
        let messages = try AIAssistance.messages(text: "午饭35", repository: r)
        XCTAssertFalse(messages.map(\.content).joined().contains("DO_NOT_SEND_PRIVATE_HISTORY"))
        let report = try AIAssistance.report(period: .month(containing: LedgerDay("2026-09-01").date()), repository: r)
        XCTAssertTrue(report.contains("净支出：1200.00")); XCTAssertFalse(report.contains("DO_NOT_SEND_PRIVATE_HISTORY"))
        XCTAssertThrowsError(try AIAssistance.messages(text: "", repository: r))
    }
    func testVisionPromptMinimizationAndImageAttachment() throws {
        let r = try LedgerRepository(container: LedgerStore.container(inMemory: true))
        try r.save(EntryDraft(amount: "1200", day: "2026-09-01", categoryID: "expense.daily.2", note: "DO_NOT_SEND_PRIVATE_HISTORY"))
        let bill = try BillImage.prepare(try SyntheticImage.jpeg(width: 64, height: 64))
        let messages = try AIAssistance.visionMessages(bill: bill, repository: r, description: " 昨晚 ")
        XCTAssertEqual(messages.count, 2)
        XCTAssertFalse(messages.map(\.content).joined().contains("DO_NOT_SEND_PRIVATE_HISTORY"))
        XCTAssertNil(messages[0].imageParts)
        let parts = try XCTUnwrap(messages[1].imageParts)
        XCTAssertEqual(parts.count, 1); XCTAssertTrue(parts[0].hasPrefix("data:image/jpeg;base64,"))
        XCTAssertTrue(messages[1].content.contains(#""description":"昨晚""#))
        XCTAssertTrue(messages[1].content.contains(#""source":"用户提供的支付账单截图""#))
        let withoutDescription = try AIAssistance.visionMessages(bill: bill, repository: r)
        XCTAssertFalse(withoutDescription[1].content.contains("description"))
        XCTAssertThrowsError(try AIAssistance.visionMessages(bill: bill, repository: r, description: String(repeating: "字", count: 2001)))
        let config = LLMConfiguration(name: "Synthetic", baseURL: "https://example.invalid/v1", model: "vision-model")
        let request = try ChatCompletionsProvider.request(configuration: config, key: nil, messages: messages, json: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "vision-model")
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        let sent = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(sent[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, messages[1].content)
        XCTAssertEqual((content[1]["image_url"] as? [String: String])?["url"], bill.dataURL)
    }
    func testImageCategoryIsNotOverriddenBySupplementaryText() throws {
        let r = try LedgerRepository(container: LedgerStore.container(inMemory: true))
        let output = try AICandidate.decode(#"{"kind":"expense","amount":"35.00","day":"2026-10-01","categoryID":"expense.clothing.0","accountID":null,"note":"衣服"}"#)
        let image = AIAssistance.candidate(output, repository: r, originalText: "午饭", preferLocalCategory: false)
        XCTAssertEqual(image.draft.categoryID, "expense.clothing.0")
        let text = AIAssistance.candidate(output, repository: r, originalText: "午饭")
        XCTAssertEqual(text.draft.categoryID, "expense.daily.2")
        let uncertain = AIAssistance.candidate(try AICandidate.decode(#"{"categoryID":null}"#), repository: r, originalText: "午饭", preferLocalCategory: false)
        XCTAssertNil(uncertain.draft.categoryID)
        XCTAssertTrue(r.entries.isEmpty)
    }
    func testKeychainConfigurationReopenChangeDestinationAndRemoval() throws {
        let scope = UUID().uuidString, defaults = UserDefaults(suiteName: UUID().uuidString)!
        let vault = KeychainVault(service: "LotBillTests." + scope)
        let settings = AISettings(defaults: defaults, scope: scope, vault: vault)
        var config = LLMConfiguration(name: "Test", baseURL: "https://a.invalid/v1", model: "model")
        try settings.save(config, key: "synthetic-secret")
        let oldID = try XCTUnwrap(settings.configuration?.id)
        defer { try? vault.write(nil, id: oldID); try? settings.remove() }
        XCTAssertEqual(try vault.read(oldID), "synthetic-secret")
        let metadata = try XCTUnwrap(defaults.data(forKey: "lotbill.ai." + scope))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("synthetic-secret"))
        let reopened = AISettings(defaults: defaults, scope: scope, vault: vault)
        XCTAssertEqual(reopened.configuration, settings.configuration)
        config = settings.configuration!; config.timeout = 40
        try settings.save(config, key: ""); XCTAssertEqual(try vault.read(oldID), "synthetic-secret")
        config.baseURL = "https://b.invalid/v1"; try settings.save(config, key: "")
        XCTAssertNotEqual(settings.configuration?.id, oldID); XCTAssertNil(try vault.read(settings.configuration!.id)); XCTAssertNil(try vault.read(oldID))
        try settings.remove(); XCTAssertNil(settings.configuration)
    }
}

@MainActor final class BackupRestoreTests: XCTestCase {
    let dining = "expense.daily.2"
    private func repo() throws -> LedgerRepository { try LedgerRepository(container: LedgerStore.container(inMemory: true)) }
    func testStatisticsExportMatchesDisplayedTotalsAndProducesReadableXLSX() throws {
        let r = try populated()
        let period = LedgerPeriod.month(containing: try LedgerDay("2026-09-01").date())
        let report = try r.statisticsExport(period: period)
        let file = try TabularFile.parse(data: report.xlsx(), name: "statistics.xlsx")
        XCTAssertEqual(file.sheets.map(\.name), ["收支汇总", "一级分类", "二级分类"])
        XCTAssertEqual(file.sheets[0].cell(row: 4, column: 1).text, "1350.00")
        XCTAssertEqual(file.sheets[0].cell(row: 5, column: 1).text, "5000.25")
        XCTAssertEqual(file.sheets[1].cell(row: 2, column: 0).text, "日常支出")
        XCTAssertEqual(file.sheets[1].cell(row: 2, column: 1).text, "1350.00")
        XCTAssertEqual(file.sheets[2].cell(row: 2, column: 1).text, "餐饮")
        XCTAssertEqual(file.sheets[2].cell(row: 2, column: 2).text, "1350.00")
        let csv = report.csv()
        XCTAssertEqual(Array(csv.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertTrue(try TabularFile.csv(csv).rows.allSatisfy { $0.count == 7 })
        XCTAssertFalse(String(decoding: csv, as: UTF8.self).contains(r.entries[0].id))
        try r.saveCategory(id: dining, name: "=测试&<分类>", parentID: "expense.daily", kind: .expense)
        let renamed = try r.statisticsExport(period: period)
        let safe = try TabularFile.parse(data: renamed.xlsx(), name: "safe.xlsx")
        XCTAssertEqual(safe.sheets[2].cell(row: 2, column: 1).text, "=测试&<分类>")
        XCTAssertFalse(safe.sheets[2].cell(row: 2, column: 1).formula)
        XCTAssertTrue(String(decoding: renamed.csv(), as: UTF8.self).contains("'=测试&<分类>"))
    }
    func testStatisticsExportMarksUnsplitHistoryAndAnnualCategoryTotals() throws {
        let r = try populated()
        let partial = try r.statisticsExport(period: LedgerPeriod(start: "2025-02-01", end: "2025-02-28"))
        let text = String(decoding: partial.csv(), as: UTF8.self)
        XCTAssertTrue(text.contains("已知净支出")); XCTAssertTrue(text.contains("部分数据未拆分"))
        let annual = try r.statisticsExport(period: LedgerPeriod(start: "2025-01-01", end: "2025-12-31"))
        let file = try TabularFile.parse(data: annual.xlsx(), name: "annual.xlsx")
        XCTAssertEqual(file.sheets[0].cell(row: 4, column: 1).text, "100.00")
        XCTAssertEqual(file.sheets[1].cell(row: 2, column: 1).text, "100.00")
        XCTAssertEqual(file.sheets[2].rows.count, 3)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func populated() throws -> LedgerRepository {
        let r = try repo()
        try r.saveAccount(name: "现金"); try r.saveAccount(name: "卡")
        try r.save(EntryDraft(amount: "1200", day: "2026-09-01", categoryID: dining, accountID: r.accounts[0].id, note: "中文, \"备注\"\n下一行"))
        let original = r.entries[0]
        try r.save(EntryDraft(kind: .refund, amount: "100", day: "2026-09-02", originalEntryID: original.id))
        try r.save(EntryDraft(kind: .transfer, amount: "50", day: "2026-09-03", accountID: r.accounts[0].id, destinationAccountID: r.accounts[1].id))
        try r.save(EntryDraft(kind: .income, amount: "5000.25", day: "2026-09-04", categoryID: "income.other"))
        let file = try TabularFile.parse(data: Data("大类,分类,金额\n日常支出,餐饮,100\n日常支出,超市,0".utf8), name: "synthetic.csv")
        var mapping = ImportMapping(); mapping.lastRow = 3; mapping.year = 2025
        try r.importFile(r.preview(file: file, mapping: mapping, purpose: .history))
        _ = try r.saveStatement(month: "2026-09", values: [dining: 135000])
        let item = try XCTUnwrap(r.statementItems.first { $0.amountCents != nil })
        try r.reviseAdjustment(itemID: item.id, expectedCents: 25000, reason: "首轮修订")
        try r.save(EntryDraft(amount: "250", day: "2026-09-05", categoryID: dining))
        try r.reviseAdjustment(itemID: item.id, expectedCents: 0, reason: "明细补全")
        try r.reviewStatement(XCTUnwrap(r.statements.first))
        return r
    }
    func testBackupRoundTripAllEntitiesAndSameIDReplacement() throws {
        let r = try populated(), backup = try r.backup(), bytes = try backup.encoded()
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("apiKey"))
        let decoded = try LedgerBackup.decode(bytes)
        let target = try repo(), folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try target.save(EntryDraft(amount: "1", day: "2026-10-01", categoryID: dining))
        let old = try target.backup()
        let recovery = try target.restore(decoded, expectedRevision: target.revision, directory: folder)
        XCTAssertEqual(try LedgerBackup.read(url: recovery).entries, old.entries)
        var restored = try target.backup(); restored.createdAt = decoded.createdAt
        XCTAssertEqual(try restored.encoded(), bytes)
        try target.restore(decoded, expectedRevision: target.revision, directory: folder)
        XCTAssertEqual(target.entries.count, decoded.entries.count)
        XCTAssertEqual(target.adjustments.count, 2)
        XCTAssertEqual(target.adjustments.filter(\.isActive).count, 1)
    }
    func testRestoreRollbackAndRecoveryWriteFailurePreserveOriginal() throws {
        let target = try populated(), incoming = try repo().backup(), original = try target.backup(), folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try target.restore(incoming, expectedRevision: target.revision, directory: folder, beforeSave: { throw LedgerError.invalid("injected failure") }))
        var after = try target.backup(); after.createdAt = original.createdAt
        XCTAssertEqual(try after.encoded(), try original.encoded())
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try LedgerBackup.read(url: recovery).entries, original.entries)
        let invalidFolder = folder.appendingPathComponent("file"); try Data().write(to: invalidFolder)
        XCTAssertThrowsError(try target.restore(incoming, expectedRevision: target.revision, directory: invalidFolder))
        XCTAssertEqual(target.entries.count, original.entries.count)
        XCTAssertThrowsError(try target.restore(incoming, expectedRevision: target.revision - 1, directory: folder))
    }
    func testCorruptionUnknownVersionDuplicatesAndReferencesRejected() throws {
        let r = try populated(), good = try r.backup()
        var bad = good; bad.version = 99
        XCTAssertThrowsError(try LedgerBackup.decode(JSONEncoder().encode(bad)))
        XCTAssertThrowsError(try LedgerBackup.decode(Data("truncated".utf8)))
        bad = good; bad.entries.append(bad.entries[0]); XCTAssertThrowsError(try bad.validate())
        bad = good; bad.entries[0].accountID = "missing"; XCTAssertThrowsError(try bad.validate())
        bad = good; bad.categories[0].parentID = bad.categories[0].id; XCTAssertThrowsError(try bad.validate())
        bad = good; bad.statementItems[0].statementID = "missing"; XCTAssertThrowsError(try bad.validate())
        bad = good; bad.adjustments[0].statementItemID = "missing"; XCTAssertThrowsError(try bad.validate())
        bad = good; bad.histories[0].precision = "month"; XCTAssertThrowsError(try bad.validate())
        bad = good; bad.histories[0].batchID = "missing"; XCTAssertThrowsError(try bad.validate())
        // The imported first-level history covers child-category entries in the same year.
        bad = good; let plain = try XCTUnwrap(bad.entries.firstIndex { e in e.kindRaw == "expense" && !good.entries.contains { $0.originalEntryID == e.id } })
        bad.entries[plain].day = "2025-06-01"; XCTAssertThrowsError(try bad.validate())
        bad = good; bad.audits.removeAll { $0.kind == "import" }; XCTAssertThrowsError(try bad.validate())
        bad = good; bad.entries[0].amountCents = -1; XCTAssertThrowsError(try bad.validate())
        bad = good; bad.adjustments[0].isActive = true; bad.adjustments[1].isActive = true; XCTAssertThrowsError(try bad.validate())
    }
    func testStatementReferencedCategoryCannotBecomeParent() throws {
        let r = try repo()
        try r.saveCategory(name: "Synthetic root", parentID: nil, kind: .expense)
        let id = try XCTUnwrap(r.categories.first { $0.name == "Synthetic root" }?.id)
        _ = try r.saveStatement(month: "2026-09", values: [id: 100])
        XCTAssertThrowsError(try r.saveCategory(name: "Child", parentID: id, kind: .expense))
        XCTAssertNoThrow(try r.backup())
    }
    func testRestoredStoreSurvivesReopenAndRefundRulesRemainValid() throws {
        let original = try populated().backup(), folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ledger.store")
        do {
            let target = try LedgerRepository(container: LedgerStore.container(url: url))
            try target.restore(original, expectedRevision: target.revision, directory: folder.appendingPathComponent("recovery"))
        }
        let reopened = try LedgerRepository(container: LedgerStore.container(url: url))
        XCTAssertEqual(reopened.entries.count, original.entries.count); XCTAssertEqual(reopened.audits.count, original.audits.count)
        let expense = try XCTUnwrap(reopened.entries.first { $0.amountCents == 120000 })
        XCTAssertThrowsError(try reopened.delete(expense))
        XCTAssertTrue(reopened.statements.first?.isReviewed == true)
    }
    func testCSVExactAmountsUnicodeEscapeInjectionAndRecordSeparation() throws {
        let r = try populated(), month = LedgerPeriod.month(containing: try LedgerDay("2026-09-01").date())
        try r.save(EntryDraft(amount: "0.10", day: "2026-09-06", categoryID: dining, note: "  =HYPERLINK(\"https://invalid\")"))
        let export = try r.csv(kind: .entries, period: month)
        XCTAssertEqual(Array(export.data.prefix(3)), [0xEF, 0xBB, 0xBF]); XCTAssertEqual(export.count, 6)
        let parsed = try TabularFile.csv(export.data)
        XCTAssertTrue(parsed.rows.contains { $0[13].text == "中文, \"备注\"\n下一行" })
        XCTAssertTrue(parsed.rows.contains { $0[13].text.hasPrefix("'=") }); XCTAssertTrue(parsed.rows.contains { $0[4].text == "0.10" })
        XCTAssertFalse(export.preview.contains("synthetic-secret"))
        let partial = try r.csv(kind: .history, period: .month(containing: LedgerDay("2025-02-01").date()))
        XCTAssertEqual(partial.count, 2); XCTAssertTrue(partial.preview.contains("2025-12-31")); XCTAssertTrue(partial.preview.contains("跨所选范围"))
        let adjustments = try r.csv(kind: .adjustments, period: month, includeInactive: true)
        XCTAssertEqual(adjustments.count, 2); XCTAssertTrue(adjustments.preview.contains("adjustment"))
        let comparison = try r.csv(kind: .reconciliation, period: month)
        XCTAssertTrue(comparison.preview.contains("未提供")); XCTAssertTrue(comparison.preview.contains("1350.00"))
        XCTAssertEqual(CSVField.text("\n@SUM(A1)").escaped, "\"'\n@SUM(A1)\"")
        XCTAssertEqual(CSVField.number("-150.00").escaped, "\"-150.00\"")
    }
}

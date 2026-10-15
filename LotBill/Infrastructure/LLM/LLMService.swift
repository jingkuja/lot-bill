import Foundation
import Security
import Observation

struct LLMConfiguration: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var name = ""
    var baseURL = ""
    var model = ""
    var timeout: Double = 30
    var maximumTokens = 1024
    var retries = 0
    var jsonMode = true
    var legacyTokenLimit = false
    var identity: String { name + "\n" + baseURL + "\n" + model }
    func endpoint() throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 200,
              (5...120).contains(timeout), (128...8192).contains(maximumTokens), (0...2).contains(retries),
              let url = URL(string: baseURL), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              baseURL.count <= 2048 else { throw LedgerError.invalid("请填写服务名、HTTPS Base URL 和模型；超时 5–120 秒，输出 128–8192 tokens，重试 0–2 次。URL 不可含密钥、查询或片段。") }
        return url.appendingPathComponent("chat/completions")
    }
}

struct KeychainVault: Sendable {
    let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "LotBill") + ".llm." + LedgerStore.scope) { self.service = service }
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    func read(_ id: String) throws -> String? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw LedgerError.invalid("无法读取 Keychain 密钥，请解锁设备后重试。") }
        return key
    }
    func write(_ key: String?, id: String) throws {
        let q = query(id)
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LedgerError.invalid("无法删除 Keychain 密钥。") }
            return
        }
        guard key.utf8.count <= 4096, !key.contains("\r"), !key.contains("\n") else { throw LedgerError.invalid("密钥格式无效。") }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(q.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw LedgerError.invalid("无法保存 Keychain 密钥。") }
        } else if status != errSecSuccess { throw LedgerError.invalid("无法更新 Keychain 密钥。") }
    }
}

@MainActor @Observable final class AISettings {
    private(set) var configuration: LLMConfiguration?
    let vault: KeychainVault
    private let defaults: UserDefaults
    private let storageKey: String
    init(defaults: UserDefaults = .standard, scope: String = LedgerStore.scope, vault: KeychainVault = KeychainVault()) {
        self.defaults = defaults; self.vault = vault; storageKey = "lotbill.ai." + scope
        if let data = defaults.data(forKey: storageKey) { configuration = try? JSONDecoder().decode(LLMConfiguration.self, from: data) }
    }
    func save(_ proposed: LLMConfiguration, key: String, removeKey: Bool = false) throws {
        _ = try proposed.endpoint()
        var config = proposed
        let sameDestination = configuration?.identity == proposed.identity
        if !sameDestination { config.id = UUID().uuidString }
        if !key.isEmpty || removeKey || !sameDestination { try vault.write(removeKey || key.isEmpty ? nil : key, id: config.id) }
        let data = try JSONEncoder().encode(config)
        if !sameDestination, let old = configuration {
            do { try vault.write(nil, id: old.id) }
            catch { try? vault.write(nil, id: config.id); throw error }
        }
        defaults.set(data, forKey: storageKey); configuration = config
    }
    func remove() throws {
        if let configuration { try vault.write(nil, id: configuration.id) }
        defaults.removeObject(forKey: storageKey); configuration = nil
    }
}

struct LLMMessage: Codable, Sendable {
    let role: String
    let content: String
    // Image data URLs appended as multimodal parts; nil keeps the plain-text protocol.
    var imageParts: [String]?
    init(role: String, content: String, images: [String] = []) {
        self.role = role
        self.content = content
        imageParts = images.isEmpty ? nil : images
    }
}
protocol LLMProvider: Sendable {
    func complete(configuration: LLMConfiguration, key: String?, messages: [LLMMessage], json: Bool) async throws -> String
}

// Credentials and financial text must never follow a redirect or enter caches/log output.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
struct ChatCompletionsProvider: LLMProvider {
    var configurationFactory: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    static let maximumResponseBytes = 256 * 1024
    static let maximumRequestBytes = 128 * 1024
    static let maximumImageRequestBytes = 12 * 1024 * 1024
    static func messageBody(_ message: LLMMessage) throws -> [String: Any] {
        let parts = message.imageParts ?? []
        guard !parts.isEmpty else { return ["role": message.role, "content": message.content] }
        guard parts.count <= 4, parts.allSatisfy({ $0.hasPrefix("data:image/") && $0.utf8.count <= maximumImageRequestBytes }) else {
            throw LedgerError.invalid("图片格式无效，请重新选择截图。")
        }
        var content: [[String: Any]] = [["type": "text", "text": message.content]]
        content += parts.map { ["type": "image_url", "image_url": ["url": $0]] as [String: Any] }
        return ["role": message.role, "content": content]
    }
    static func request(configuration: LLMConfiguration, key: String?, messages: [LLMMessage], json: Bool) throws -> URLRequest {
        var request = URLRequest(url: try configuration.endpoint(), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty {
            guard !key.contains("\n"), !key.contains("\r"), key.utf8.count <= 4096 else { throw LedgerError.invalid("密钥格式无效。") }
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let bodies = try messages.map(Self.messageBody)
        let hasImages = messages.contains { !($0.imageParts ?? []).isEmpty }
        var body: [String: Any] = ["model": configuration.model, "messages": bodies, "stream": false]
        body[configuration.legacyTokenLimit ? "max_tokens" : "max_completion_tokens"] = configuration.maximumTokens
        if json && configuration.jsonMode { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let limit = hasImages ? maximumImageRequestBytes : maximumRequestBytes
        guard (request.httpBody?.count ?? 0) <= limit else {
            throw LedgerError.invalid(hasImages ? "截图压缩后仍超过发送上限，请裁剪后重试。" : "发送内容过大，请缩小范围。")
        }
        return request
    }
    static func decode(_ data: Data, status: Int) throws -> String {
        guard data.count <= maximumResponseBytes else { throw LedgerError.invalid("服务返回内容过大。") }
        guard (200...299).contains(status) else {
            switch status {
            case 401, 403: throw LedgerError.invalid("服务拒绝认证，请检查密钥和权限。")
            case 429: throw LedgerError.invalid("服务限流，请稍后重试或手动记账。")
            case 300...399: throw LedgerError.invalid("服务返回重定向，已停止发送；请核对实际端点。")
            default: throw LedgerError.invalid("服务请求失败（HTTP \(status)），可稍后重试或手动记账。")
            }
        }
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?; let refusal: String? }
                let message: Message; let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Envelope.self, from: data), let choice = response.choices.first,
              choice.finish_reason == "stop", choice.message.refusal == nil,
              let content = choice.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.invalid("服务返回了无效、拒绝或截断的结果；请重试或手动填写。")
        }
        return content
    }
    func complete(configuration: LLMConfiguration, key: String?, messages: [LLMMessage], json: Bool) async throws -> String {
        let request = try Self.request(configuration: configuration, key: key, messages: messages, json: json)
        let config = configurationFactory()
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = configuration.timeout; config.timeoutIntervalForResource = configuration.timeout
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for attempt in 0...configuration.retries {
            try Task.checkCancellation()
            do {
                let (stream, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw LedgerError.invalid("服务响应格式无效。") }
                defer { stream.task.cancel() }
                if (http.statusCode == 429 || (500...599).contains(http.statusCode)), attempt < configuration.retries {
                    try await Task.sleep(for: .seconds(attempt + 1)); continue
                }
                var data = Data()
                for try await byte in stream {
                    try Task.checkCancellation()
                    guard data.count < Self.maximumResponseBytes else { throw LedgerError.invalid("服务返回内容过大。") }
                    data.append(byte)
                }
                return try Self.decode(data, status: http.statusCode)
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if error.code == .timedOut { throw LedgerError.invalid("请求超时，输入已保留，可重试或手动记账。") }
                throw LedgerError.invalid("网络连接失败，输入已保留，可手动记账。")
            }
        }
        throw LedgerError.invalid("请求未完成。")
    }
}

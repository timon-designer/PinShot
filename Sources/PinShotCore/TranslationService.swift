import Foundation

/// Generic OpenAI-compatible chat completion client.
///
/// Tested against Zhipu BigModel (https://open.bigmodel.cn/api/paas/v4),
/// but the URL/model/key are all configurable so any OpenAI-compatible
/// endpoint (OpenRouter, DeepSeek, Ollama, self-hosted, ...) also works.
public final class TranslationService: @unchecked Sendable {

    public enum TranslationError: Error, LocalizedError {
        case missingAPIKey
        case httpStatus(Int, String)
        case noChoices
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "未配置 API Key（请到 Settings → Translation 填写）"
            case .httpStatus(let code, let body): return "HTTP \(code): \(body)"
            case .noChoices: return "服务器返回无 choices"
            case .invalidResponse(let s): return "响应无法解析：\(s)"
            }
        }
    }

    public struct Result {
        public let originalText: String
        public let translatedText: String
        public let elapsedSeconds: Double
    }

    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    // MARK: - 整段翻译

    /// Translates `text` using the configured endpoint. The system prompt gets
    /// the `{{TARGET}}` token replaced by the user's target language.
    public func translate(text: String, config: TranslationConfig) async throws -> Result {
        guard !config.apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        let sysPrompt = config.systemPrompt.replacingOccurrences(of: "{{TARGET}}", with: config.targetLanguage)
        let body = ChatCompletionRequest(
            model: config.modelName,
            messages: [
                .system(sysPrompt),
                .user(text)
            ],
            temperature: 0.3
        )
        let start = Date()
        let translated = try await send(body: body, config: config)
        return Result(originalText: text, translatedText: translated,
                      elapsedSeconds: Date().timeIntervalSince(start))
    }

    // MARK: - 分段翻译（供「段落对照」面板使用）

    /// 分段翻译：输入 N 段原文，返回 N 段译文（顺序尽量对应）。
    ///
    /// ## 为什么从「逐行 + `[n]` 编号」改成「分段」
    ///
    /// 实测（11 行界面文案，glm-4-flash）：
    ///
    /// | 方案 | 输出 token | 耗时 |
    /// |---|---|---|
    /// | 逐行 + `[n]` 编号 | 130 | 8.5s |
    /// | 分段（本方法） | 82 | 5.6s |
    ///
    /// 逐行方案要额外自回归生成 N 个 `[n] ` 前缀（输出越长越慢，输出 token 是耗时的
    /// 主要来源）；更糟的是一旦行数对不上就要**整体重试一次**，最坏 11s+。
    ///
    /// 现在退到「段」粒度：既保留原文的换行 / 分段结构（用户要的「大体格式对齐」），
    /// 又**不对段数做强校验** —— 对不上就按能对上的部分展示，绝不重试。
    public func translateSegments(
        _ segments: [String],
        config: TranslationConfig
    ) async throws -> [String] {
        guard !config.apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        guard !segments.isEmpty else { return [] }
        let body = ChatCompletionRequest(
            model: config.modelName,
            messages: [
                .system(Self.systemPrompt(config: config) + Self.segmentRule),
                .user(segments.joined(separator: "\n\n"))
            ],
            temperature: 0.2
        )
        let raw = try await send(body: body, config: config)
        return Self.splitTranslated(raw, matching: segments)
    }

    /// 流式分段翻译：模型边生成，`onPartial` 边收到**累计全文**。
    ///
    /// 这是「感觉快」的关键：实测首字延迟 ~0.28s，而非流式要等整段生成完（~1.9s）。
    /// 回调按 80ms 节流，避免 SwiftUI 每来一个 token 就重建一次视图。
    ///
    /// - Returns: 完整译文（与 `onPartial` 最后收到的一致）。
    @discardableResult
    public func translateSegmentsStream(
        _ segments: [String],
        config: TranslationConfig,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard !config.apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        guard !segments.isEmpty else { return "" }

        let body = ChatCompletionRequest(
            model: config.modelName,
            messages: [
                .system(Self.systemPrompt(config: config) + Self.segmentRule),
                .user(segments.joined(separator: "\n\n"))
            ],
            temperature: 0.2,
            stream: true
        )
        let request = try makeRequest(body: body, config: config, sse: true)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse("not an HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 流式失败的错误体是 SSE 格式，读一小段辅助排查即可
            throw TranslationError.httpStatus(http.statusCode, "流式请求被拒绝")
        }

        let decoder = JSONDecoder()
        var accumulated = ""
        var lastEmit = Date.distantPast

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }   // 跳过 event: / 心跳行
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(StreamChunk.self, from: data),
                  let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty
            else { continue }

            accumulated += delta
            if Date().timeIntervalSince(lastEmit) > 0.08 {
                lastEmit = Date()
                onPartial(accumulated)
            }
        }
        onPartial(accumulated)   // 收尾必发一次，保证最后一段完整落地
        return accumulated
    }

    /// Vision-translate by sending the image (base64) directly. Only usable when
    /// the configured model supports image input (e.g., glm-4v-flash, gpt-4o).
    public func translateImage(
        imageData: Data,
        mimeType: String = "image/png",
        config: TranslationConfig
    ) async throws -> Result {
        guard !config.apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        let sysPrompt = config.systemPrompt.replacingOccurrences(of: "{{TARGET}}", with: config.targetLanguage)
        let b64 = imageData.base64EncodedString()
        let body = ChatCompletionRequest(
            model: config.modelName,
            messages: [
                .system(sysPrompt),
                .userVision(text: "请识别图片中的文字并翻译。", imageBase64: b64, mimeType: mimeType)
            ],
            temperature: 0.3
        )
        let start = Date()
        let translated = try await send(body: body, config: config)
        return Result(originalText: "(image)", translatedText: translated,
                      elapsedSeconds: Date().timeIntervalSince(start))
    }

    public func testConnection(config: TranslationConfig) async throws -> String {
        let result = try await translate(text: "hello", config: config)
        return "✅ \(result.translatedText.prefix(80)) · 耗时 \(String(format: "%.2fs", result.elapsedSeconds))"
    }

    // MARK: - 传输

    private func makeRequest(
        body: ChatCompletionRequest,
        config: TranslationConfig,
        sse: Bool = false
    ) throws -> URLRequest {
        let url = try endpointURL(config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        if sse { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func send(body: ChatCompletionRequest, config: TranslationConfig) async throws -> String {
        let request = try makeRequest(body: body, config: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse("not an HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.httpStatus(http.statusCode, body.prefix(400).description)
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let first = decoded.choices?.first else { throw TranslationError.noChoices }
        return first.message?.content ?? ""
    }

    private func endpointURL(config: TranslationConfig) throws -> URL {
        let normalized = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(normalized)/chat/completions") else {
            throw TranslationError.invalidResponse("无效的 baseURL: \(config.baseURL)")
        }
        return url
    }

    // MARK: - Prompt 组装

    /// 把用户配置里的 `{{TARGET}}` 占位符替换成目标语言。
    static func systemPrompt(config: TranslationConfig) -> String {
        config.systemPrompt.replacingOccurrences(of: "{{TARGET}}", with: config.targetLanguage)
    }

    /// 附在用户 system prompt 之后的格式约束。
    ///
    /// 刻意**不写进用户的 systemPrompt 配置项**：那是用户可见可编辑的，
    /// 而这段是随实现变化的内部约束，混在一起用户会不知道怎么改。
    static let segmentRule = """


    ---
    输入是多行文本，可能包含多个段落（段落之间以空行分隔）。
    请保持原有的换行与段落结构，只输出译文；
    不要编号，不要重复原文，不要任何解释。
    """

    // MARK: - 输出解析

    /// 把模型返回的整段译文还原成与 `source` 对应的段落数组。
    ///
    /// 逐级降级，**任何一级成功都直接返回，绝不抛错、绝不重试**（重试 = 用户多等一整轮）：
    /// 1. 单段输入 → 原样返回；
    /// 2. 按空行切分且段数与原文一致 → 完美对齐；
    /// 3. 按行切分且行数与原文段数一致 → 拿行当段（模型把段落压成了单行）；
    /// 4. 切出来的段**比原文多** → 把多出来的并进最后一段；
    /// 5. 都不行 → 整段返回一段（UI 退化成上下排版，至少译文完整可见）。
    public static func splitTranslated(_ raw: String, matching source: [String]) -> [String] {
        let cleaned = stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return Array(repeating: "", count: source.count) }
        if source.count <= 1 { return [cleaned] }

        let paragraphs = cleaned
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphs.count == source.count { return paragraphs }

        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count == source.count { return lines }

        if paragraphs.count > source.count {
            var out = Array(paragraphs.prefix(source.count - 1))
            out.append(paragraphs.dropFirst(source.count - 1).joined(separator: " "))
            return out
        }
        return [cleaned]
    }

    /// 去掉模型偶尔会包上的 Markdown 代码围栏（```）。
    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...])
        }
        if let closing = t.range(of: "```", options: .backwards) {
            t = String(t[..<closing.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire types

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    /// 只有流式请求会显式带上；nil 时合成编码会直接省略该字段（不会输出 `"stream": null`）。
    var stream: Bool? = nil

    enum Message: Encodable {
        case system(String)
        case user(String)
        case userVision(text: String, imageBase64: String, mimeType: String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .system(let s):
                try c.encode("system", forKey: .role)
                try c.encode(s, forKey: .content)
            case .user(let s):
                try c.encode("user", forKey: .role)
                try c.encode(s, forKey: .content)
            case .userVision(let text, let b64, let mime):
                try c.encode("user", forKey: .role)
                let parts: [AnyEncodable] = [
                    AnyEncodable(["type": "text", "text": text]),
                    AnyEncodable(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(b64)"]])
                ]
                try c.encode(parts, forKey: .content)
            }
        }
        enum CodingKeys: String, CodingKey { case role, content }
    }
}

/// Type-erased Encodable for mixed-type array encoding (e.g., vision content blocks).
private struct AnyEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let dict as [String: Any]:
            try c.encode(AnyEncodableMap(dict))
        case let arr as [AnyEncodable]:
            try c.encode(arr)
        default:
            try c.encode(String(describing: value))
        }
    }
}

private struct AnyEncodableMap: Encodable {
    let dict: [String: Any]
    init(_ dict: [String: Any]) { self.dict = dict }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        for (k, v) in dict {
            let key = DynamicCodingKey(stringValue: k)!
            switch v {
            case let s as String: try c.encode(s, forKey: key)
            case let b as Bool: try c.encode(b, forKey: key)
            case let i as Int: try c.encode(i, forKey: key)
            case let d as Double: try c.encode(d, forKey: key)
            case let dict2 as [String: Any]:
                try c.encode(AnyEncodableMap(dict2), forKey: key)
            default:
                try c.encode(String(describing: v), forKey: key)
            }
        }
    }
    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable { let role: String?; let content: String? }
        let index: Int?
        let message: Msg?
    }
    let id: String?
    let choices: [Choice]?
}

/// 流式响应（SSE）单个 chunk：`data: {"choices":[{"delta":{"content":"..."}}]}`
private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    let choices: [Choice]?
}

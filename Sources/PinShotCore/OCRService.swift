import Foundation
import Vision
import AppKit
import CoreGraphics

/// 一段连续文本（可含多行），行序为阅读顺序。
///
/// 分段的目的是给翻译一个「自然段」粒度：比单行更有上下文（译文更通顺），
/// 又比整张图分得更细（译文能保留原文的段落/换行结构）。
public struct TextSegment: Sendable, Equatable {
    public let lines: [String]

    public init(lines: [String]) { self.lines = lines }

    /// 段内多行以换行连接 —— 送进模型时保留换行，模型才有可能在译文里保留。
    public var text: String { lines.joined(separator: "\n") }
}

/// Apple Vision OCR wrapper.
///
/// ⚠️ 并发要点（Swift 6 严格并发）—— 改动前请先读完
///
/// Vision 的 `VNRequest` completion handler 由 Vision 在**内部后台队列**回调。
/// 若该闭包是在 `@MainActor` 上下文中创建的，Swift 6 会把闭包推断为 MainActor
/// 隔离的；随后它在后台线程执行时触发运行时 executor 校验：
///
///     dispatch_assert_queue_fail → _swift_task_checkIsolatedSwift → SIGTRAP
///
/// 表现就是「一按翻译就闪退」（本 App 真实踩过，exit code 133）。
///
/// 因此这里**刻意不使用 completion handler**：`VNImageRequestHandler.perform(_:)`
/// 本身是同步阻塞 API，返回后 `request.results` 已就绪，在同一个非隔离闭包里
/// 直接读取即可 —— 既绕开隔离校验，也免掉非 Sendable 捕获警告。
public enum OCRService {

    public enum OCRError: Error, LocalizedError {
        case noTextFound
        case visionFailure(Error)

        public var errorDescription: String? {
            switch self {
            case .noTextFound: return "图片中未识别到文字"
            case .visionFailure(let e): return "OCR 失败：\(e.localizedDescription)"
            }
        }
    }

    // MARK: - 分段识别（推荐：供「段落对照」翻译使用）

    /// 入口：从 `NSImage` 识别文字并**按行间距自动分段**。
    ///
    /// `NSImage` / `NSBitmapImageRep` 不是 `Sendable`，转换必须在主线程完成；
    /// 拿到 `CGImage`（是 `Sendable`）后再交给非隔离实现去跑 Vision。
    @MainActor
    public static func recognizeSegments(
        in image: NSImage,
        languages: [String] = ["zh-Hans", "en-US"]
    ) async throws -> [TextSegment] {
        guard let cgImage = cgImageFromNSImage(image) else {
            throw OCRError.visionFailure(
                NSError(domain: "OCR", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "无法转换为 CGImage"])
            )
        }
        return try await recognizeSegments(inCGImage: cgImage, languages: languages)
    }

    /// 非隔离实现：真正跑 Vision。**必须是非隔离的**，理由见文件头注释。
    nonisolated public static func recognizeSegments(
        inCGImage cgImage: CGImage,
        languages: [String] = ["zh-Hans", "en-US"]
    ) async throws -> [TextSegment] {
        let langs = languages
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // request / handler 都在闭包内部创建，避免跨隔离捕获非 Sendable 类型。
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = langs
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])   // 同步返回，results 此时已就绪
                } catch {
                    continuation.resume(throwing: OCRError.visionFailure(error))
                    return
                }

                guard let observations = request.results, !observations.isEmpty else {
                    continuation.resume(throwing: OCRError.noTextFound)
                    return
                }

                // 排序：先按 midY 降序（Vision y 向上 → 上到下），同行再按 minX 升序（左到右）
                let ordered = observations.sorted { a, b in
                    let ay = a.boundingBox.midY
                    let by = b.boundingBox.midY
                    if abs(ay - by) > 0.01 { return ay > by }
                    return a.boundingBox.minX < b.boundingBox.minX
                }

                let boxes: [(text: String, box: CGRect)] = ordered.compactMap { obs in
                    guard let raw = obs.topCandidates(1).first?.string else { return nil }
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return (text, obs.boundingBox)
                }

                guard !boxes.isEmpty else {
                    continuation.resume(throwing: OCRError.noTextFound)
                    return
                }
                continuation.resume(returning: group(boxes))
            }
        }
    }

    /// 按行间距把相邻行聚成「段」。
    ///
    /// Vision 坐标系原点在**左下**、y 向上，所以相邻两行的垂直间隙是
    /// **上一行的 `minY` 减去下一行的 `maxY`**（不是 maxY - minY，容易写反）。
    ///
    /// 阈值取行高中位数的 0.65 倍：正常行距（约 0.3~0.5 倍行高）不分段，
    /// 段落之间 / 列表项之间 / 标题与正文之间那种明显空档才会切段。
    /// 默认行为是「宁合不拆」—— 分段太细反而会让译文变碎。
    nonisolated static func group(_ boxes: [(text: String, box: CGRect)]) -> [TextSegment] {
        guard !boxes.isEmpty else { return [] }

        let heights = boxes.map { $0.box.height }.sorted()
        let median = heights[heights.count / 2]
        let threshold = max(median * 0.65, 0.008)

        var segments: [TextSegment] = []
        var current: [String] = []
        var previous: CGRect?

        for item in boxes {
            if let p = previous {
                let gap = p.minY - item.box.maxY
                if gap > threshold, !current.isEmpty {
                    segments.append(TextSegment(lines: current))
                    current = []
                }
            }
            current.append(item.text)
            previous = item.box
        }
        if !current.isEmpty { segments.append(TextSegment(lines: current)) }
        return segments
    }

    // MARK: - 逐行识别（保留旧接口）

    /// 拍平所有段的行，得到按阅读顺序排列的行数组。
    @MainActor
    public static func recognizeLines(
        in image: NSImage,
        languages: [String] = ["zh-Hans", "en-US"]
    ) async throws -> [String] {
        try await recognizeSegments(in: image, languages: languages).flatMap(\.lines)
    }

    nonisolated public static func recognizeLines(
        inCGImage cgImage: CGImage,
        languages: [String] = ["zh-Hans", "en-US"]
    ) async throws -> [String] {
        try await recognizeSegments(inCGImage: cgImage, languages: languages).flatMap(\.lines)
    }

    // MARK: - 整体识别（保留旧接口）

    /// 把所有识别结果按换行拼成一整段文本。保留给不需要段落对照的调用方。
    @MainActor
    public static func recognizeText(
        in image: NSImage,
        languages: [String] = ["zh-Hans", "en-US"]
    ) async throws -> String {
        try await recognizeSegments(in: image, languages: languages)
            .map(\.text)
            .joined(separator: "\n\n")
    }

    @MainActor
    private static func cgImageFromNSImage(_ image: NSImage) -> CGImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.cgImage
    }
}

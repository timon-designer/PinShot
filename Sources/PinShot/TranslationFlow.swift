import Cocoa
import SwiftUI
import PinShotCore

// MARK: - 数据模型

/// 一个「段落对」：一段原文 + 对应译文。
///
/// 粒度是**段**而不是**行** —— OCR 会按行间距把相邻行聚成自然段（见 `OCRService.group`），
/// 一段可以包含多行（段内换行保留）。这样译文既有上下文（通顺），
/// 又保留了原文的段落/换行结构（用户要的「大体格式对齐」）。
struct TranslationRow: Identifiable, Equatable {
    let id = UUID()
    let original: String
    var translated: String
}

/// 面板的可观察状态。
@MainActor
final class TranslationResultState: ObservableObject {
    /// 原文段（先落地，译文随后逐段填入）。
    @Published var originals: [String] = []
    /// 段落对照行。流式翻译时 `translated` 会实时增长。
    @Published var rows: [TranslationRow] = []
    /// 进行中 / 警告 / 错误提示（nil 表示一切正常）
    @Published var status: String? = nil
    /// 标题栏右侧的副标题，例如「7 段 · 1832ms」
    @Published var header: String = ""
    /// 本次翻译的截图。翻译时遮罩会关闭（界面回到正常状态），
    /// 缩略图留在面板上，用户既能确认「翻的是哪一块」，也能随时复制原图。
    @Published var capturedImage: NSImage?
    /// 是否正在流式接收（用于显示「翻译中」的动效提示）。
    @Published var isStreaming: Bool = false
    /// 内容区**实测**高度（由视图布局后写回）。
    ///
    /// ScrollView 没有「理想高度」（它只报告滚动视口尺寸），所以不能用
    /// `NSHostingView.fittingSize` 反推面板高度 —— 那样只能拿到几十点，
    /// 结果是面板底部留一大片空白。改成由视图把真实内容高度报上来。
    @Published var contentHeight: CGFloat = 0
}

// MARK: - Flow

/// Orchestrates an OCR→translate (or vision-translate) round-trip and shows
/// the result in a floating, paragraph-aligned panel.
///
/// 设计要点：
/// - **流式**：模型边生成边把译文铺进面板（首字实测 ~0.28s），
///   不用干等整段生成完 —— 这是「感觉快」的关键。
/// - 面板层级为 `.floating`，浮在普通窗口之上、不盖菜单栏；
///   翻译时截图遮罩会关闭（界面回到正常状态）。
/// - 面板是**可复用**的：每次 `run` 都重新 `makeKeyAndOrderFront`，
///   否则用户点过「复制并关闭」后就再也看不到结果（历史 bug）。
@MainActor
final class TranslationFlow {
    static let shared = TranslationFlow()
    private init() {}

    private var service = TranslationService()
    private var resultWindow: TranslationResultWindow?
    private let state = TranslationResultState()

    /// 翻译面板当前是否可见（截图遮罩据此决定要不要让出键盘事件）。
    var isShowingResult: Bool { resultWindow?.isVisible == true }

    /// 翻译面板是否为当前 key window（遮罩的键盘拦截会让路，避免 ⌘C 被抢）。
    func ownsWindow(_ window: NSWindow?) -> Bool {
        guard let window = window, let rw = resultWindow else { return false }
        return window === rw
    }

    func run(image: NSImage, config: TranslationConfig, avoiding selection: CGRect?) {
        SnipLog.write("Translate: 开始 model=\(config.modelName) vision=\(config.isVisionModel) key=\(config.apiKey.isEmpty ? "未填" : "已填")")

        present(avoiding: selection)
        state.capturedImage = image
        state.originals = []
        state.rows = []
        state.header = "识别中…"
        state.status = "🔄 正在识别截图中的文字…"
        state.isStreaming = false

        Task { @MainActor in
            let started = Date()
            do {
                // ---------- 1) 视觉模型：图片直传（拿不到段落结构） ----------
                if config.isVisionModel {
                    SnipLog.write("Translate: 走视觉模型直传")
                    let png = try Self.pngData(from: image)
                    let r = try await service.translateImage(imageData: png, mimeType: "image/png", config: config)
                    state.originals = ["(图片)"]
                    state.rows = [TranslationRow(original: "(图片)", translated: r.translatedText)]
                    state.status = nil
                    state.header = "视觉模型 · \(Int(r.elapsedSeconds * 1000))ms"
                    resultWindow?.resizeToFit(avoiding: selection)
                    return
                }

                // ---------- 2) OCR：分段 ----------
                let segments = try await OCRService.recognizeSegments(in: image)
                let ocrMs = Int(Date().timeIntervalSince(started) * 1000)
                let lineCount = segments.reduce(0) { $0 + $1.lines.count }
                SnipLog.write("Translate: OCR 完成 \(segments.count) 段 / \(lineCount) 行，\(ocrMs)ms")
                SnipLog.write("Translate: 段0 首行=[\(segments[0].lines.first?.prefix(40) ?? "")]")

                let texts: [String] = segments.map(\.text)
                state.originals = texts
                state.rows = texts.map { TranslationRow(original: $0, translated: "") }
                state.header = "翻译中 · \(texts.count) 段"
                state.status = "🔄 正在翻译 \(texts.count) 段…"
                state.isStreaming = true
                resultWindow?.resizeToFit(avoiding: selection)

                // ---------- 3) 翻译（统一走流式） ----------
                // 即使只有 1 段也走流式：单段往往就是「行距均匀的一整块文本」
                // （清单、界面文案、逐句罗列），更需要边翻边显 + 保留换行。
                var streamed: String?
                do {
                    streamed = try await service.translateSegmentsStream(texts, config: config) { [weak self] partial in
                        // 回调在后台线程；节流已在 service 内做过（80ms）
                        Task { @MainActor in self?.renderStreaming(partial) }
                    }
                } catch {
                    // 少数 OpenAI 兼容网关不支持 SSE：退化成一次性请求，别把失败摊给用户。
                    SnipLog.write("Translate: ⚠️ 流式不可用，降级普通请求：\(error.localizedDescription)")
                }

                let parts: [String]
                if let streamed {
                    parts = TranslationService.splitTranslated(streamed, matching: texts)
                } else {
                    parts = try await service.translateSegments(texts, config: config)
                }
                state.isStreaming = false
                state.rows = texts.enumerated().map { i, original in
                    TranslationRow(original: original,
                                   translated: i < parts.count ? parts[i] : "")
                }

                let ms = Int(Date().timeIntervalSince(started) * 1000)
                SnipLog.write("Translate: ✅ 完成 \(texts.count) 段，总 \(ms)ms（含 OCR \(ocrMs)ms）")
                state.header = "\(texts.count) 段 · \(ms)ms"
                state.status = nil
                // 先按估算摆一次（面板立刻贴合），再等 SwiftUI 完成这一轮布局、
                // 把实测内容高度回写后用真实高度精修一次 —— 消除底部留白。
                resultWindow?.resizeToFit(avoiding: selection)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    self?.resultWindow?.resizeToFit(avoiding: selection)
                }

            } catch {
                SnipLog.write("Translate: ❌ \(error.localizedDescription)")
                state.isStreaming = false
                state.header = "失败"
                state.status = "❌ \(error.localizedDescription)"
                resultWindow?.resizeToFit(avoiding: selection)
            }
        }
    }

    /// 流式增量渲染：把「累计译文」铺到面板上。
    ///
    /// 模型还在生成，最后一段必然是半句 —— 照填不误，让它现场长出来。
    /// 分段优先按空行（我们就是这么发给模型的），不够用再退化为按行。
    private func renderStreaming(_ accumulated: String) {
        guard !state.originals.isEmpty else { return }

        let byParagraph = accumulated
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var pieces = byParagraph
        if pieces.count < state.originals.count {
            let byLine = accumulated
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if byLine.count > pieces.count { pieces = byLine }
        }

        var rows = state.originals.map { TranslationRow(original: $0, translated: "") }
        for (i, piece) in pieces.enumerated() where i < rows.count {
            rows[i].translated = piece
        }
        state.rows = rows
    }

    /// 确保面板存在并显示在屏幕上（每一次都要 orderFront，见类注释）。
    private func present(avoiding selection: CGRect?) {
        if resultWindow == nil {
            resultWindow = TranslationResultWindow(state: state)
        }
        // 防御性重设层级：面板可能被其它路径（贴图窗口复用等）改过 level，
        // 每次显示都强制拉回目标层级。
        resultWindow?.level = TranslationResultWindow.resultLevel
        resultWindow?.place(avoiding: selection)
        resultWindow?.makeKeyAndOrderFront(nil)
        resultWindow?.orderFrontRegardless()
        SnipLog.write("Translate: 面板显示 level=\(resultWindow?.level.rawValue ?? -1)")
    }

    static func pngData(from image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "png", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法序列化为 PNG"])
        }
        return png
    }
}

// MARK: - Result Window

final class TranslationResultWindow: NSPanel {

    private let state: TranslationResultState
    private var hostingView: NSHostingView<TranslationResultView>!
    private static let preferredWidth: CGFloat = 680
    /// 上一次摆放实际解析出的宽度（窄屏会被收窄）。
    private var resolvedWidth: CGFloat = 680

    /// 面板层级：翻译时会先关掉截图遮罩（界面回到正常状态），
    /// 所以这里用标准的 `.floating` —— 浮在普通窗口之上、方便边看边复制，
    /// 又不会盖住菜单栏这类系统 UI（`.screenSaver` 系层级会盖住一切）。
    static let resultLevel = NSWindow.Level.floating

    /// 闭包间接层：`init` 里不能捕获 `self`，用它把 `onClose` 接到实例方法上。
    private final class CloseBox { var action: (() -> Void)? }
    private let closeBox = CloseBox()

    override var canBecomeKey: Bool { true }

    /// 面板被收走时留一行日志，方便以后回归定位。
    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        if wasVisible { SnipLog.write("Translate: 面板 orderOut（关闭）") }
        super.orderOut(sender)
        // 翻译期间焦点一直在本 App 手里（用户要选文字/复制），面板关掉就还回去，
        // 否则用户 App 的浮动面板会一直被系统藏着 —— 下次截图就拍不到它们。
        if wasVisible {
            Task { @MainActor in OverlayWindowManager.shared.restoreFocusAfterPanelClosed() }
        }
    }

    init(state: TranslationResultState) {
        self.state = state
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: 320),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // 纯白弹窗：强制浅色外观，这样系统控件（分段控件、按钮）也渲染成浅色，
        // 系统切到深色模式时不会出现「白底 + 深色控件」的割裂感。
        appearance = NSAppearance(named: .aqua)

        closeBox.action = { [weak self] in self?.orderOut(nil) }
        let view = TranslationResultView(state: state, onClose: { [box = closeBox] in box.action?() })
        hostingView = NSHostingView(rootView: view)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView

        // ⚠️ 刻意**不设** `isFloatingPanel = true`。它有两个副作用：
        //   1. 把 window level 重置为 .floating(3) —— 曾让面板掉到截图遮罩(1000)下面；
        //   2. 让面板在**应用失活时自动隐藏**（Apple 文档：floating panel
        //      "hides when the application is deactivated"）—— 表现为用户切到
        //      浏览器/企微后面板自己没了。
        // 我们要的是「常驻但不抢焦点」：手动设 level + 关掉各种自动隐藏即可。
        hidesOnDeactivate = false
        canHide = false
        level = Self.resultLevel

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = true
        isMovableByWindowBackground = true
        minSize = CGSize(width: 420, height: 180)
        backgroundColor = .clear
        isOpaque = false
    }

    /// 根据选区把面板放到「一定不挡住截图」的位置。
    ///
    /// 四向优先级：右侧 → 左侧 → 上方 → 下方。侧边放不下就改用上下布局，
    /// 并把宽度收窄到可用空间（而不是死守 680pt 后被迫压在选区上）。
    func place(avoiding selection: CGRect?) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 12      // 面板与选区的间距
        let edge: CGFloat = 12     // 面板与屏幕边缘的间距
        let minSide: CGFloat = 360 // 侧边布局可接受的最小宽度

        guard let sel = selection, !sel.isEmpty else {
            let size = fittedSize(width: min(Self.preferredWidth, screen.width - edge * 2))
            resolvedWidth = size.width
            let origin = CGPoint(x: screen.maxX - size.width - 40, y: screen.maxY - size.height - 40)
            setFrame(CGRect(origin: origin, size: size), display: true)
            return
        }

        let rightSpace = screen.maxX - sel.maxX - gap - edge
        let leftSpace = sel.minX - screen.minX - gap - edge

        if rightSpace >= minSide || leftSpace >= minSide {
            // —— 侧边布局：贴选区左/右，纵向与选区顶部对齐（不超出屏幕）——
            let useRight = rightSpace >= minSide
            let available = useRight ? rightSpace : leftSpace
            let width = min(Self.preferredWidth, available)
            let size = fittedSize(width: width)
            resolvedWidth = width
            let rawX = useRight ? (sel.maxX + gap) : (sel.minX - gap - size.width)
            // 边界钳制：窗口绝不允许探出屏幕（曾有面板右边缘跑出屏幕、关闭按钮点不到）
            let x = min(max(rawX, screen.minX + edge), max(screen.minX + edge, screen.maxX - size.width - edge))
            let y = min(max(sel.maxY - size.height, screen.minY + edge),
                        max(screen.minY + edge, screen.maxY - size.height - edge))
            setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
            SnipLog.write("Translate: 面板布局 侧边\(useRight ? "右" : "左") w=\(Int(width)) x=\(Int(x)) sel=\(sel) screen=\(screen)")
        } else {
            // —— 上下布局：横向居中于选区；高度收进空隙，绝不盖住截图 ——
            let width = min(Self.preferredWidth, screen.width - edge * 2)
            var size = fittedSize(width: width)
            let above = screen.maxY - sel.maxY - gap - edge
            let below = sel.minY - screen.minY - gap - edge
            let minH: CGFloat = 180
            let y: CGFloat

            if above >= size.height {
                y = sel.maxY + gap                        // 完整放在选区上方
            } else if below >= size.height {
                y = sel.minY - gap - size.height          // 完整放在选区下方
            } else if max(above, below) >= minH {
                // 一侧能塞下一块：把高度压进那个空隙，超出内容改为滚动
                size.height = min(size.height, max(above, below))
                y = (above >= below) ? (sel.maxY + gap) : (sel.minY - gap - size.height)
            } else {
                // 连最小高度都放不下（选区几乎占满屏幕）：贴边、允许重叠，面板可拖动
                y = (above >= below) ? (screen.maxY - size.height - edge) : (screen.minY + edge)
            }
            resolvedWidth = width
            let x = min(max(sel.midX - size.width / 2, screen.minX + edge),
                        screen.maxX - size.width - edge)
            setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
            SnipLog.write("Translate: 面板布局 上下 w=\(Int(width)) h=\(Int(size.height)) above=\(Int(above)) below=\(Int(below))")
        }
    }

    /// 结果内容变化后重新适配：复用同一套摆放规则，宽度保持稳定不跳动。
    func resizeToFit(avoiding selection: CGRect?) {
        place(avoiding: selection)
    }

    /// 估算面板尺寸。高度优先问 SwiftUI 要「理想高度」。
    private func fittedSize(width: CGFloat) -> CGSize {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxHeight = screen.height * 0.72

        let height: CGFloat
        if state.contentHeight > 60 {
            // 实测内容高度 + 面板 chrome
            // （header 38 + footer 46 + 两条分隔线 + 内容上下留白 ≈ 96）
            height = min(max(200, state.contentHeight + 96), maxHeight)
        } else {
            // 兜底：按行数粗估（系数 30 ≈ 12pt 行高 + 上下内边距）
            let visualLines = max(state.rows.reduce(0) { total, row in
                total + max(row.original.components(separatedBy: .newlines).count,
                            row.translated.components(separatedBy: .newlines).count)
            }, 1)
            let chrome: CGFloat = 118 + (state.status == nil ? 0 : 26)
            let narrow = min(max(1.0, Self.preferredWidth / max(width, 1)), 1.6)
            height = min(max(200, chrome + CGFloat(visualLines) * 30 * narrow), maxHeight)
        }
        return CGSize(width: width, height: height)
    }
}

// MARK: - SwiftUI 内容

/// 内容区实测高度（ScrollView 内部量好、向上冒泡）。
///
/// 用 `static let` 而非 `static var`：Swift 6 严格并发下 `static var` 会被判定为
/// 可变全局状态而报错。
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TranslationResultView: View {
    @ObservedObject var state: TranslationResultState
    let onClose: () -> Void
    @State private var copyMode: String = "translated"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            separator
            content
            separator
            footer
        }
        // 纯白弹窗：不用 .ultraThinMaterial（那是 macOS 毛玻璃，后面透出桌面很糊）。
        .background(Palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
    }

    /// 纯白弹窗的固定配色。刻意写死而不是用语义色：
    /// 面板强制浅色外观，写死色值才不会在系统深色模式下变成白底白字。
    enum Palette {
        static let background = Color.white
        static let border = Color(red: 0.85, green: 0.85, blue: 0.87)
        static let separator = Color(red: 0.92, green: 0.92, blue: 0.93)
        static let stripe = Color(red: 0.97, green: 0.97, blue: 0.98)
        static let text = Color(red: 0.11, green: 0.11, blue: 0.12)
        static let muted = Color(red: 0.53, green: 0.55, blue: 0.59)
        static let faint = Color(red: 0.78, green: 0.79, blue: 0.81)
        static let warning = Color(red: 0.76, green: 0.43, blue: 0.04)
        static let accent = Color(red: 0.20, green: 0.44, blue: 0.90)
    }

    private var separator: some View {
        Rectangle().fill(Palette.separator).frame(height: 1)
    }

    // MARK: 标题

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble.fill").foregroundColor(Palette.muted)
            Text("翻译")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.text)
            if let image = state.capturedImage {
                thumbnail(image)
            }
            if state.isStreaming {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            }
            if !state.header.isEmpty {
                Text(state.header)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
                    .lineLimit(1)
            }
            Spacer()
            // 这里刻意不用 Button：SwiftUI 的 Button 走的是 ButtonBehavior 状态机，
            // 在「视图重建 + 窗口重新显示」的边界情况下，曾把一个非用户点击
            // 当成 action 调用（栈：ButtonBehavior.ended → ButtonAction.callAsFunction），
            // 表现为翻译面板莫名其妙自己关掉。onTapGesture 只响应真实点击，绕开该状态机。
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(Palette.faint)
                .contentShape(Rectangle())
                .onTapGesture {
                    SnipLog.write("Translate: 点关闭")
                    onClose()
                }
                .help("关闭翻译面板")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 截图缩略图：界面已回到正常状态，这里保留「翻的是哪一块」的线索，
    /// 点一下可把原图复制到剪贴板。
    private func thumbnail(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 52, maxHeight: 28)
            .padding(2)
            .background(Palette.stripe)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Palette.border, lineWidth: 0.5)
            )
            .help("本次翻译的截图 · 点击复制图片")
            .onTapGesture { copyImage(image) }
    }

    private func copyImage(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // MARK: 段落对照正文

    private var content: some View {
        GeometryReader { geo in
            // 原文列宽随面板宽度自适应（窄面板下不至于把译文挤没）
            let originalColumn = max(110, min(248, geo.size.width * 0.36))
            // ⚠️ 译文列必须给**具体宽度**，不能用 `maxWidth: .infinity`：
            // ScrollView 内部是「无界宽度」环境，`.infinity` 会把整个 HStack 的
            // 理想宽度算成无穷大 → 内容按居中对齐溢出两边 → 左列每行首字母被裁掉
            // （真实踩过，肉眼表现为「译文列把原文列挤出去了」）。
            let translatedColumn = max(80, geo.size.width - 24 - originalColumn - 14)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if state.rows.isEmpty {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(state.status ?? "…")
                                .font(.system(size: 12))
                                .foregroundColor(Palette.muted)
                        }
                        .frame(width: geo.size.width)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(Array(state.rows.enumerated()), id: \.element.id) { idx, row in
                            HStack(alignment: .top, spacing: 14) {
                                Text(row.original)
                                    .font(.system(size: 12))
                                    .foregroundColor(Palette.muted)
                                    .lineSpacing(2)
                                    .multilineTextAlignment(.leading)
                                    .textSelection(.enabled)
                                    .frame(width: originalColumn, alignment: .leading)
                                if row.translated.isEmpty {
                                    // 还没翻到这一段：留一条呼吸动效，避免像卡死
                                    Rectangle()
                                        .fill(Palette.separator)
                                        .frame(width: translatedColumn, height: 13)
                                        .opacity(0.7)
                                } else {
                                    Text(row.translated)
                                        .font(.system(size: 13))
                                        .foregroundColor(Palette.text)
                                        .lineSpacing(3)
                                        .multilineTextAlignment(.leading)
                                        .textSelection(.enabled)
                                        .frame(width: translatedColumn, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(width: geo.size.width, alignment: .leading)
                            .background(idx.isMultiple(of: 2) ? Color.clear : Palette.stripe)
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .padding(.vertical, 4)
                .background(
                    // 把内容的真实高度报给窗口，窗口据此贴合（ScrollView 自己报不出理想高度）
                    GeometryReader { g in
                        Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                    }
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onPreferenceChange(ContentHeightKey.self) { h in
            if abs(h - state.contentHeight) > 2 { state.contentHeight = h }
        }
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack(spacing: 8) {
            if let status = state.status, !state.rows.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.warning)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Picker("", selection: $copyMode) {
                Text("译文").tag("translated")
                Text("对照").tag("both")
                Text("原文").tag("original")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)

            Button("复制") { copy(close: false) }
            Button("复制并关闭") { copy(close: true) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func copy(close: Bool) {
        let text: String
        switch copyMode {
        case "original":
            text = state.rows.map(\.original).joined(separator: "\n\n")
        case "both":
            text = state.rows.map { "\($0.original)\n\($0.translated)" }.joined(separator: "\n\n")
        default:
            text = state.rows.map(\.translated).joined(separator: "\n\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if close { onClose() }
    }
}

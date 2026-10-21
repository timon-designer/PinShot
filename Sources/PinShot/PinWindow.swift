import Cocoa
import SwiftUI
import PinShotCore

@MainActor
final class PinWindowManager: ObservableObject {
    static let shared = PinWindowManager()

    @Published private(set) var activePins: [PinWindow] = []
    private var pinKeyMonitor: Any?

    private init() {
        setupKeyMonitor()
    }

    private func setupKeyMonitor() {
        pinKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, !self.activePins.isEmpty else { return event }
            
            // Check if key event is intended for a focused PinWindow
            if let keyWindow = NSApp.keyWindow as? PinWindow {
                let isCmd = event.modifierFlags.contains(.command)
                // ⌘W (key 13) or Esc (key 53)
                if (isCmd && event.keyCode == 13) || event.keyCode == 53 {
                    self.closePin(keyWindow)
                    return nil
                }
                // ⌘C (key 8)
                if isCmd && event.keyCode == 8 {
                    PasteboardService.shared.copyImage(keyWindow.baseImage)
                    SoundService.shared.playCaptureSound()
                    return nil
                }
            }
            return event
        }
    }

    func createPin(image: NSImage, at origin: CGPoint? = nil) {
        let pin = PinWindow(image: image, initialOrigin: origin)
        activePins.append(pin)
        pin.show()
        SoundService.shared.playPinSound()
    }

    func closePin(_ pin: PinWindow) {
        pin.orderOut(nil)
        activePins.removeAll(where: { $0.pinID == pin.pinID })
    }

    func closeAllPins() {
        for pin in activePins {
            pin.orderOut(nil)
        }
        activePins.removeAll()
    }
}

final class PinHostingView<Content: View>: NSHostingView<Content> {
    weak var pinWindow: PinWindow?
    private var initialFrameOnPinch: CGRect = .zero

    // MARK: - 手动拖窗状态
    //
    // ⚠️ 为什么必须自己实现拖动，而不是靠 isMovableByWindowBackground：
    // 对照实验（三个同规格窗口，同一套合成鼠标事件）结果如下 ——
    //   W1 NSHostingView 原样（mouseDownCanMoveWindow == true）→ 21 个 mouseDown/mouseDragged
    //      全部送达视图，窗口坐标**一动不动**
    //   W2 同上 + 覆写 mouseDownCanMoveWindow = true → 同样一动不动
    //   W3 纯 NSView 手动 mouseDragged 移动窗口 → 精确跟随（+70,+70）
    // 结论：borderless + .nonactivatingPanel 的 NSPanel 上 AppKit **不会**启动背景拖窗，
    // 与 mouseDownCanMoveWindow 无关。所以只能在视图层手动搬窗口。
    private var isDraggingWindow = false
    private var dragAnchorMouse: NSPoint = .zero    // 屏幕坐标（全局，左下原点）
    private var dragAnchorOrigin: NSPoint = .zero

    /// responder 链上的 magnify 是否真的送达过。
    /// 送达过就让 NSMagnificationGestureRecognizer 闭嘴，避免同一次捏合被两条路径重复应用。
    private var didReceiveResponderMagnify = false

    /// 持有识别器的 delegate（NSGestureRecognizer.delegate 是 weak）。
    private let pinchDelegate = PinGestureRecognizerDelegate()

    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        self.allowedTouchTypes = [.direct, .indirect]

        // 兜底：只有 responder 链上的 magnify(with:) 收不到事件时，这个识别器才接手。
        let pinchRecognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        pinchRecognizer.delaysPrimaryMouseButtonEvents = false
        pinchRecognizer.delaysOtherMouseButtonEvents = false
        pinchRecognizer.delegate = pinchDelegate
        self.addGestureRecognizer(pinchRecognizer)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// ⚠️ 必须覆写。默认 false 时，当 SnipShot 不是前台 App，**第一次点击会被系统
    /// 吞掉**（用来激活窗口，不派发给视图）——实测表现为「贴图浮在别的 App 上时
    /// 按住拖不动，得先点一下再拖」，而贴图本来就常驻在别的 App 之上，这是主场景。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⚠️ 兜底把整个窗口矩形纳入命中范围。
    /// SwiftUI 对「没有内容的区域」（PinContentView 最外圈 16px 光晕留白）返回 nil，
    /// 于是那一圈完全收不到 mouseDown —— 拖动和 hover 全部失效。
    /// 实测：仅靠 SwiftUI 的 .contentShape(Rectangle()) 只能修好圆角附近（内缩 19px 生效），
    /// 修不了留白圈（内缩 ≤15px 仍然收不到事件）。这里在 AppKit 层补一刀。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    // MARK: - 手动拖窗
    // 关键：mouseDown 之后照常 super，让 SwiftUI 继续收到事件 ——
    // hover 按钮、右键菜单、双击关闭都不受影响；只有「按住并移动」才搬窗口。

    override func mouseDown(with event: NSEvent) {
        if let win = window {
            dragAnchorMouse = NSEvent.mouseLocation
            dragAnchorOrigin = win.frame.origin
            isDraggingWindow = true
            SnipLog.write("Pin: mouseDown 起锚 mouse=\(NSStringFromPoint(dragAnchorMouse)) win=\(NSStringFromPoint(dragAnchorOrigin))")
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isDraggingWindow, let win = window {
            let now = NSEvent.mouseLocation
            win.setFrameOrigin(NSPoint(x: dragAnchorOrigin.x + (now.x - dragAnchorMouse.x),
                                       y: dragAnchorOrigin.y + (now.y - dragAnchorMouse.y)))
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingWindow, let win = window {
            SnipLog.write("Pin: 拖动结束 origin=\(NSStringFromPoint(win.frame.origin)) size=\(NSStringFromSize(win.frame.size))")
        }
        isDraggingWindow = false
        super.mouseUp(with: event)
    }

    @objc private func handlePinchGesture(_ recognizer: NSMagnificationGestureRecognizer) {
        // responder 链上的 magnify(with:) 已经在处理了 → 这条兜底路径让位，避免重复缩放。
        guard !didReceiveResponderMagnify else { return }
        guard let win = pinWindow else { return }
        switch recognizer.state {
        case .began:
            initialFrameOnPinch = win.frame
        case .changed:
            let scale = max(0.15, 1.0 + recognizer.magnification)
            let baseW = initialFrameOnPinch.width * scale
            let newWidth = max(min(baseW, 3500), win.minSize.width)
            let newHeight = newWidth * (initialFrameOnPinch.height / initialFrameOnPinch.width)

            let deltaW = newWidth - initialFrameOnPinch.width
            let deltaH = newHeight - initialFrameOnPinch.height
            let newX = initialFrameOnPinch.origin.x - (deltaW / 2)
            let newY = initialFrameOnPinch.origin.y - (deltaH / 2)

            win.setFrame(CGRect(x: newX, y: newY, width: newWidth, height: newHeight), display: true, animate: false)
        default:
            break
        }
    }

    override func magnify(with event: NSEvent) {
        // 标记 responder 路径可用 → NSMagnificationGestureRecognizer 兜底路径自动停用。
        if !didReceiveResponderMagnify {
            didReceiveResponderMagnify = true
            SnipLog.write("Pin: 捏合走 responder 链 (magnify(with:))，停用识别器兜底路径")
        }
        pinWindow?.handleMagnifyEvent(event)
    }

    override func smartMagnify(with event: NSEvent) {
        pinWindow?.handleSmartMagnify(event)
    }

    // MARK: - Scroll-wheel zoom (anchor on cursor)
    override func scrollWheel(with event: NSEvent) {
        guard let win = pinWindow else { super.scrollWheel(with: event); return }

        // ⚠️ 必须取「主导轴」而不是只看 scrollingDeltaY：
        // 按住 ⇧ 滚轮时 macOS 会把垂直滚动**转成横向滚动**，实测拿到的是
        // scrollingDeltaY=0 / scrollingDeltaX=+3，只看 Y 就会让「⇧ 粗调」彻底失效
        // （表现为转了半天一点反应都没有）。横向取正值即与纵向「远离自己 = 放大」同向。
        let dyRaw = event.scrollingDeltaY
        let dxRaw = event.scrollingDeltaX
        var delta = abs(dyRaw) >= abs(dxRaw) ? dyRaw : dxRaw

        // 归一化到「物理方向」：不论系统是否开启「自然滚动」，滚轮/双指远离自己 → 正值 → 放大。
        // 少了这一步，缩放方向会随「自然滚动」开关翻转（实测：原实现滚轮向上反而是缩小）。
        if event.isDirectionInvertedFromDevice { delta = -delta }

        // Option = 细调，Shift = 粗调
        let step: CGFloat = event.modifierFlags.contains(.option) ? 0.01
                          : (event.modifierFlags.contains(.shift) ? 0.10 : 0.04)
        // 鼠标滚轮一格 ≈ 1 行；触控板给的是像素级小数，需要额外衰减，否则一划就飞。
        let deviceScale: CGFloat = event.hasPreciseScrollingDeltas ? 0.15 : 1.0

        let factor = min(max(1.0 + delta * step * deviceScale, 0.5), 2.0)
        guard factor != 1.0 else {
            SnipLog.write(String(format: "Pin: 滚轮忽略 dx=%.2f dy=%.2f mods=%lu precise=%d",
                                 dxRaw, dyRaw, event.modifierFlags.rawValue,
                                 event.hasPreciseScrollingDeltas ? 1 : 0))
            return
        }

        // 以鼠标全局坐标为锚点缩放：光标下的那一像素在缩放前后保持不动，不会「跳位」。
        win.handleCursorAnchoredZoom(factor: factor, mouseGlobal: NSEvent.mouseLocation)
        SnipLog.write(String(format: "Pin: 滚轮 dx=%.2f dy=%.2f mods=%lu precise=%d → factor=%.3f size=%@",
                             dxRaw, dyRaw, event.modifierFlags.rawValue,
                             event.hasPreciseScrollingDeltas ? 1 : 0, factor,
                             NSStringFromSize(win.frame.size)))
    }
}

/// `NSGestureRecognizer.delegate` 是 weak，所以必须由外部强引用持有。
/// （不能把 conformance 写在 PinHostingView 的 extension 里 —— 泛型类的 extension
///  不允许出现 @objc 成员，编译器会直接报错。）
@MainActor
final class PinGestureRecognizerDelegate: NSObject, NSGestureRecognizerDelegate {
    /// 允许和 SwiftUI 自己的识别器并存，别互相把对方顶掉。
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        true
    }
}

final class PinWindow: NSPanel {
    let pinID = UUID()
    let baseImage: NSImage
    public static let glowPadding: CGFloat = 16

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: NSImage, initialOrigin: CGPoint? = nil) {
        self.baseImage = image
        let imageSize = image.size
        let maxInitialWidth: CGFloat = 600
        let scale = (imageSize.width > 0 && imageSize.width > maxInitialWidth) ? maxInitialWidth / imageSize.width : 1.0
        let baseW = max(imageSize.width * scale, 60)
        let baseH = max(imageSize.height * scale, 40)
        let totalW = baseW + (Self.glowPadding * 2)
        let totalH = baseH + (Self.glowPadding * 2)
        let windowSize = CGSize(width: totalW, height: totalH)

        let initialRect: CGRect
        if let origin = initialOrigin {
            // Inset so the screenshot content aligns with original captured position
            let adjX = origin.x - Self.glowPadding
            let adjY = origin.y - Self.glowPadding
            initialRect = CGRect(origin: CGPoint(x: adjX, y: adjY), size: windowSize)
        } else {
            let screenRect = NSScreen.main?.visibleFrame ?? CGRect(x: 100, y: 100, width: 800, height: 600)
            let x = screenRect.midX - (windowSize.width / 2)
            let y = screenRect.midY - (windowSize.height / 2)
            initialRect = CGRect(x: x, y: y, width: windowSize.width, height: windowSize.height)
        }

        super.init(
            contentRect: initialRect,
            // ⚠️ 这里刻意**不带 .resizable**。
            // 带 .resizable 时，borderless 窗口的最外圈会留一条约 11px 宽的「边缘 resize 感应带」，
            // 实测距窗口边缘 2~10px 处按下会被 AppKit 当成拉角缩放而不是拖窗；而那条带正好
            // 落在 16px 的透明光晕圈里（肉眼完全看不见），于是「按着贴图边想拖」会莫名其妙把
            // 贴图缩小。贴图的缩放已经有滚轮 / 双指捏合 / 双指双击复位三条明确路径，不需要这条
            // 隐藏的边缘拖拽，所以直接去掉，让**整个窗口矩形都是拖动面**（验收① 按住任意位置可拖）。
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Ensure window never gets hidden when user switches to other apps
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false // Shadow/Aura handled natively by PinAuraGlowView
        // ⚠️ 必须 false。实测 borderless + .nonactivatingPanel 的 NSPanel 上
        // isMovableByWindowBackground **完全不生效**（详见 PinHostingView 的对照实验记录），
        // 拖动改由 PinHostingView.mouseDragged 手动实现。这里留 true 只会造成
        // 万一某版本 AppKit 生效时「双倍位移」，所以显式关掉，保证只有一条拖动路径。
        self.isMovableByWindowBackground = false
        if totalW > 0 && totalH > 0 {
            self.aspectRatio = windowSize
            self.minSize = CGSize(width: 120, height: max(120 * (totalH / totalW), 70))
        }

        setupContentView()
    }

    private func setupContentView() {
        let contentView = PinContentView(
            image: baseImage,
            onClose: { [weak self] in
                guard let self = self else { return }
                PinWindowManager.shared.closePin(self)
            },
            onCopy: { [weak self] in
                guard let self = self else { return }
                PasteboardService.shared.copyImage(self.baseImage)
                SoundService.shared.playCaptureSound()
            },
            onSave: { [weak self] in
                guard let self = self else { return }
                self.saveImage()
            }
        )
        let hostingView = PinHostingView(rootView: contentView)
        hostingView.pinWindow = self
        self.contentView = hostingView
    }

    func show() {
        self.orderFrontRegardless()
        self.makeKeyAndOrderFront(nil)
    }

    // MARK: - 2-Finger Pinch-to-Resize
    // 与滚轮共用同一套「以鼠标为锚点」的缩放数学，保证两种手势的观感一致。
    // event.magnification 是**逐事件增量**（非累计），可直接当 factor 用。
    func handleMagnifyEvent(_ event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor != 1.0 else { return }
        let sizeBefore = self.frame.size
        handleCursorAnchoredZoom(factor: factor, mouseGlobal: NSEvent.mouseLocation)
        SnipLog.write(String(format: "Pin: 捏合 magnification=%.4f factor=%.4f → size %@ → %@",
                             event.magnification, factor,
                             NSStringFromSize(sizeBefore), NSStringFromSize(self.frame.size)))
    }

    func handleSmartMagnify(_ event: NSEvent) {
        let imageSize = baseImage.size
        let baseW = imageSize.width + (Self.glowPadding * 2)
        let baseH = imageSize.height + (Self.glowPadding * 2)
        
        var currentFrame = self.frame
        let deltaW = baseW - currentFrame.width
        let deltaH = baseH - currentFrame.height
        currentFrame.origin.x -= deltaW / 2
        currentFrame.origin.y -= deltaH / 2
        currentFrame.size = CGSize(width: baseW, height: baseH)
        
        self.setFrame(currentFrame, display: true, animate: true)
    }

    /// Cursor-anchored zoom. `mouseGlobal` is in AppKit global coords (bottom-left origin)
    /// and is preserved at its current frame-position across the resize.
    func handleCursorAnchoredZoom(factor: CGFloat, mouseGlobal: CGPoint) {
        guard factor != 1.0 else { return }
        var frame = self.frame
        let oldW = frame.width
        let newW = max(self.minSize.width, min(3500, oldW * factor))
        guard newW != oldW else { return }
        let newH = newW * (frame.height / oldW)
        let realFactor = newW / oldW

        // Keep mouseGlobal anchored at the same position within the frame.
        let dxFromOrigin = mouseGlobal.x - frame.origin.x
        let dyFromOrigin = mouseGlobal.y - frame.origin.y
        frame.origin.x = mouseGlobal.x - dxFromOrigin * realFactor
        frame.origin.y = mouseGlobal.y - dyFromOrigin * realFactor
        frame.size = CGSize(width: newW, height: newH)

        self.setFrame(frame, display: true, animate: false)
    }

    override func mouseDown(with event: NSEvent) {
        self.orderFrontRegardless()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let isCmd = event.modifierFlags.contains(.command)
        if (isCmd && event.keyCode == 13) || event.keyCode == 53 { // ⌘W or Esc
            PinWindowManager.shared.closePin(self)
            return
        }
        if isCmd && event.keyCode == 8 { // ⌘C
            PasteboardService.shared.copyImage(self.baseImage)
            SoundService.shared.playCaptureSound()
            return
        }
        if isCmd && event.keyCode == 1 { // ⌘S
            self.saveImage()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCmd = event.modifierFlags.contains(.command)
        if isCmd && event.keyCode == 13 { // ⌘W
            PinWindowManager.shared.closePin(self)
            return true
        }
        if isCmd && event.keyCode == 8 { // ⌘C
            PasteboardService.shared.copyImage(self.baseImage)
            SoundService.shared.playCaptureSound()
            return true
        }
        if isCmd && event.keyCode == 1 { // ⌘S
            self.saveImage()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func saveImage() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "SnipShot_\(Int(Date().timeIntervalSince1970)).png"

        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self = self else { return }
            if let tiff = self.baseImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }
}

struct PinContentView: View {
    let image: NSImage
    let onClose: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void

    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var isHovering: Bool = false
    @State private var opacity: Double = 1.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Image Content with matched Background Glow Aura
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .opacity(opacity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(
                    PinAuraGlowView(
                        cornerRadius: 10,
                        style: settingsManager.settings.pinShadowStyle,
                        isHovering: isHovering
                    )
                )
                // Double tap / double click to close pin automatically
                .onTapGesture(count: 2) {
                    onClose()
                }

            // Hover Action Overlay
            if isHovering {
                HStack(spacing: 6) {
                    // Quick Action Buttons
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(5)
                            .background(Color.black.opacity(0.65))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("复制图片 (⌘C)")

                    Button(action: onSave) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(5)
                            .background(Color.black.opacity(0.65))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("保存图片 (⌘S)")

                    // Close Button (✕)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(5)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭贴图 (⌘W / Esc / 双击)")
                }
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(PinWindow.glowPadding) // Generous margin ensuring glow fades to transparent without clipping
        // ⚠️ 给「整块窗口矩形」铺一层 1/255 的黑（≈0.5% 不透明度，肉眼不可见）。
        // 目的不是装饰：最外圈 16px 光晕留白是全透明的，而 macOS 会把**全透明像素**
        // 上的点击直接透传给下面的窗口 —— 于是那一圈的 mouseDown 根本到不了本 App，
        // 「按住任意位置拖动」和 hover 一起失效（实测：内缩 ≤16px 完全收不到事件）。
        // 只要像素不是 alpha=0，点击就会正常落到窗口上。
        .background(Color.black.opacity(0.005))
        // 再配合 contentShape 把命中外形拉成矩形，避免圆角把角上的点击判掉。
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                self.isHovering = hovering
            }
        }
        .contextMenu {
            Button("复制图片 (⌘C)", action: onCopy)
            Button("图片另存为… (⌘S)", action: onSave)
            Divider()
            Menu("阴影 / 光晕样式") {
                ForEach(PinShadowStyle.allCases, id: \.self) { style in
                    Button(style.displayName) {
                        settingsManager.settings.pinShadowStyle = style
                    }
                }
            }
            Menu("透明度") {
                Button("100%") { opacity = 1.0 }
                Button("75%") { opacity = 0.75 }
                Button("50%") { opacity = 0.50 }
                Button("25%") { opacity = 0.25 }
            }
            Divider()
            Button("关闭贴图 (⌘W / Esc)", action: onClose)
        }
    }
}

import Cocoa
import SwiftUI
import PinShotCore

final class OverlayWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        // ⚠️ `.nonactivatingPanel` 是「不打扰用户 App」的关键：
        // 带这个样式 + canBecomeKey=true 时，遮罩可以成为 key window 收键盘，
        // 但**不会把前台 App 顶下去**（实测：另一个 App 的 isActive 全程保持 YES，
        // 我们照样收到 keyDown）。没有它，任何 makeKey 都会激活本 App。
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel),
                   backing: backingStoreType, defer: flag)
        hidesOnDeactivate = false
    }
}

@MainActor
final class OverlayWindowManager: NSObject, FloatingToolbarDelegate {
    static let shared = OverlayWindowManager()

    private var overlayWindows: [NSWindow] = []
    private var capturedFrames: [CapturedScreenFrame] = []
    private var localKeyMonitor: Any?
    private var didRegisterActivationObserver = false

    // MARK: - 悬浮工具条（单实例复用）
    //
    // 以前的实现每次 showToolbar 都 new 一个 NSHostingView 塞进面板，而
    // updateSelection（拖动选区时每帧一次）又会调 showToolbar —— 等于每秒
    // 重建几十次带 AutoLayout 约束的 contentView，最终在 AppKit 的约束解算
    // 事务里抛 NSException，整 app 闪退。现在：面板和视图各只建一次，
    // 状态走 FloatingToolbarModel，摆放请求按 runloop 合并。
    private var toolbarPanel: FloatingToolbarPanel?
    private var toolbarHosting: NSHostingView<FloatingToolbarView>?
    private let toolbarModel = FloatingToolbarModel()
    /// 等待摆放的选区（同一 runloop 内多次请求会被合并成一次）。
    private var pendingToolbarSelection: CGRect?
    private var toolbarUpdateScheduled = false
    /// 上一次真正生效的窗口矩形，相同就不动窗口。
    private var lastToolbarFrame: CGRect?
    /// 同一次摆放里的补拍次数（标注栏展开后尺寸会变，需要再来一轮）。
    private var toolbarPass = 0
    /// 连续异常重建次数上限控制：异常 → 重建 → 再异常不能变成死循环。
    private var toolbarRecoveryCount = 0

    // MARK: - 焦点交接（修「浮窗截不到 / 浮窗被关闭」）
    //
    // 截图必须让本 App 成为 active 才能拿到键盘（遮罩要成 key window）。
    // 代价是：用户原来的 App 会被 deactivate —— 它的浮动面板只要是
    // hidesOnDeactivate（NSPanel 的常见默认）就会被系统**立刻藏起来**；
    // 而本 App 截完图又不把焦点还回去，那些浮窗就一直不恢复。
    // 于是下一次按快捷键时，冻结帧里就少了这些浮窗（"截不到"），
    // 用户眼里则是"每按一次快捷键就有浮窗被关掉"。
    //
    // 修法：进截图前记住前台 App、出截图时把焦点还回去；
    // 万一冻结那一刻自己还占着前台，先把焦点还回去、等一等再冻结。
    /// 上一次「非本 App」的前台应用，用来归还焦点。
    private var lastExternalFrontApp: NSRunningApplication?
    /// 本次截图开始时用户的前台应用。
    private var previousFrontApp: NSRunningApplication?
    private var didObserveWorkspaceActivation = false
    
    var currentSelection: SelectionRect?
    var annotationDoc = AnnotationDocument()
    var history = HistoryStack<AnnotationDocument>(initialState: AnnotationDocument())
    
    var activeTool: AnnotationToolType = .select
    var activeColor: ColorRepresentation = .red
    var activeStrokeWidth: CGFloat = 3.0
    var isAnnotating: Bool = false

    func startCapture() {
        SnipLog.write("Capture: startCapture() 进入")

        // Ensure screen recording permission
        guard PermissionService.shared.checkPermission() else {
            SnipLog.write("Capture: 无屏幕录制权限 → 弹引导窗口")
            PermissionWindowManager.shared.show { [weak self] in
                self?.startCapture()
            }
            return
        }

        // 这里刻意不归还焦点：本次流程马上要自己接管焦点，
        // 先激活别人再冻结会形成竞态。真正的前后焦点交接在下面显式处理。
        closeOverlay(restoreFocus: false)
        observeWorkspaceActivationIfNeeded()

        // 记下「这次该还给谁」：正常是当前前台 App；若前台已经是自己，
        // 就退回上一次记录的外部 App。
        let currentFront = NSWorkspace.shared.frontmostApplication
        previousFrontApp = (currentFront?.bundleIdentifier == Bundle.main.bundleIdentifier)
            ? lastExternalFrontApp
            : currentFront

        // 关键前置：冻结帧必须拍到「用户自己的桌面」。
        // 只有「本 App 真的是前台」时才需要把焦点交回去 —— 现在遮罩走
        // nonactivating 方案，正常情况下我们从来不会抢前台。
        if isFrontmostApp, let target = (previousFrontApp ?? lastExternalFrontApp), !target.isTerminated {
            SnipLog.write("Capture: ⚠️ 自己仍占着前台 → 先归还焦点给 \(target.localizedName ?? "?")，120ms 后再冻结")
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.beginCaptureSession()
            }
            return
        }
        beginCaptureSession()
    }

    /// 本进程是否真的是「系统层面的前台 App」。
    /// ⚠️ 不能用 `NSApp.isActive`：nonactivating panel 成为 key window 时
    /// `isActive` 也会是 true，但前台其实还是用户那个 App。
    private var isFrontmostApp: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// 冻结帧 + 开遮罩。从 `startCapture` 抽出来，方便「先归还焦点再冻结」这条异步路径复用。
    private func beginCaptureSession() {
        // 1. Freeze screen frames（必须在 NSApp.activate 之前！）
        capturedFrames = CaptureService.shared.captureAllScreens()
        SnipLog.write("Capture: 冻结帧数 = \(capturedFrames.count) 前台=\(previousFrontApp?.localizedName ?? "-") selfFrontmost=\(isFrontmostApp) 屏幕窗口数=\(Self.onScreenWindowCount())")
        annotationDoc = AnnotationDocument()
        history.reset(with: annotationDoc)
        currentSelection = nil
        isAnnotating = false
        // 每次重新截图都从干净状态起手：工具条状态归位、异常重建预算复位。
        toolbarModel.isAnnotating = false
        toolbarModel.selectedTool = .rectangle
        toolbarRecoveryCount = 0
        toolbarPass = 0

        // 2. 开遮罩（⚠️ 刻意**不调用 NSApp.activate**）
        //
        //    以前这里写的是 `NSApp.activate(ignoringOtherApps: true)`，
        //    这是「浮窗被关闭 / 浮窗截不到」的根因：
        //    强制激活本 App 会把用户正在用的 App 顶成非活跃 ——
        //      · 那些依赖激活状态的浮动面板/弹出面板（弹窗、面板式工具栏、
        //        微信独立聊天窗等）会被系统或 App 自己收起 → 用户看到「浮窗被关掉」；
        //      · 而且截完图焦点也不还回去，这些面板一直不复原，
        //        下一次截图冻结帧里自然就没有它们 → 用户看到「浮窗截不到」。
        //
        //    正确做法（实测于 macOS 27）：遮罩用 `.nonactivatingPanel` +
        //    canBecomeKey，只 orderFrontRegardless + makeKey。
        //    这样遮罩照样拿到 key window（本地键盘监听正常工作，Esc/T/P/⌘C 都在），
        //    但前台 App **全程保持活跃**，一个浮窗都不会被碰。
        registerActivationObserverIfNeeded()

        // 3. Open overlay window on each display
        for screen in NSScreen.screens {
            let window = createOverlayWindow(for: screen)
            overlayWindows.append(window)
            window.orderFrontRegardless()   // 不抢激活，只压在最上层
            window.makeKey()                // nonactivating panel：拿键盘但不激活 App
            SnipLog.write("Capture: 遮罩 window=\(NSStringFromRect(window.frame)) visible=\(window.isVisible) key=\(window.isKeyWindow) 前台仍为=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        }

        // 4. Setup event monitor for guaranteed instant keyboard shortcut handling
        setupKeyMonitor()

        // activate 是异步的，激活真正完成后还要补一次 makeKey（见 didBecomeActive 回调）。
        perform(#selector(ensureOverlayIsKey), with: nil, afterDelay: 0.05)

        SnipLog.write("Capture: ✅ 遮罩已显示，共 \(overlayWindows.count) 个窗口")
    }

    /// 应用激活后把键盘焦点补给遮罩。
    private func registerActivationObserverIfNeeded() {
        guard !didRegisterActivationObserver else { return }
        didRegisterActivationObserver = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive() {
        ensureOverlayIsKey()
    }

    // MARK: - 焦点交接

    /// 持续跟踪「用户自己的工作 App」：只要前台不是本 App 就记下来。
    /// 有了它，即使某次截图异常退出，下一次也能知道该把焦点还给谁。
    private func observeWorkspaceActivationIfNeeded() {
        guard !didObserveWorkspaceActivation else { return }
        didObserveWorkspaceActivation = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func workspaceDidActivateApplication(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalFrontApp = app
    }

    /// 把焦点还给用户原来的 App。
    /// 归还之后，它那些 hidesOnDeactivate 的浮动面板会被系统自动还原 ——
    /// 这正是「下次截图还能拍到它们」的前提。
    private func restoreUserFocus() {
        // 只有当「系统前台真的是我们」时才需要还 —— 走 nonactivating 遮罩时
        // 前台一直是用户的 App，这里直接返回，绝不去抢。
        guard isFrontmostApp else { return }
        guard let target = previousFrontApp ?? lastExternalFrontApp,
              !target.isTerminated else { return }
        // 只激活 App 本身，不强行把它所有窗口提上来 —— 保持用户的窗口层级原样。
        target.activate(options: [])
        SnipLog.write("Capture: 焦点已归还 → \(target.localizedName ?? "?")")
    }

    /// 供其它浮窗（翻译面板等）关闭后归还焦点 —— 否则本 App 会一直占着前台，
    /// 用户 App 的浮动面板也就一直不恢复。
    func restoreFocusAfterPanelClosed() {
        restoreUserFocus()
    }

    /// 冻结帧时刻屏幕上还有多少窗口（诊断用：数字突然变小通常意味着有浮窗被藏了）。
    private static func onScreenWindowCount() -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return (list as? [[String: Any]])?.count ?? -1
    }

    /// 让遮罩成为 key window —— 遮罩收到键盘的前提。
    @objc private func ensureOverlayIsKey() {
        guard let target = overlayWindows.first, target.isVisible else { return }
        if !target.isKeyWindow {
            target.makeKey()
            SnipLog.write("Capture: 补 makeKey → key=\(target.isKeyWindow) appActive=\(NSApp.isActive)")
        }
    }

    private func setupKeyMonitor() {
        removeKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, !self.overlayWindows.isEmpty else { return event }
            // 翻译面板在前台时让出键盘：否则在面板里按 ⌘C 会被遮罩
            // 当成「复制截图」。面板关闭后行为自动恢复。
            if TranslationFlow.shared.isShowingResult,
               TranslationFlow.shared.ownsWindow(NSApp.keyWindow) {
                return event
            }
            if self.handleKeyEvent(event) {
                return nil // Event consumed
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let isCmd = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 53: // Esc: Cancel selection and close overlay
            closeOverlay()
            return true

        case 35: // P (Pin) or ⌘P
            if let sel = currentSelection, !sel.isEmpty {
                toolbarDidSelectPin()
                return true
            }

        case 8: // C (Copy) or ⌘C
            if let sel = currentSelection, !sel.isEmpty {
                toolbarDidSelectCopy()
                return true
            }

        case 36: // Enter / Return (Copy & Finish)
            if let sel = currentSelection, !sel.isEmpty {
                toolbarDidSelectCopy()
                return true
            }

        case 1: // S (Save) or ⌘S
            if let sel = currentSelection, !sel.isEmpty {
                toolbarDidSelectSave()
                return true
            }

        case 17: // T (Translate) — only when configured
            if !isCmd && currentSelection != nil && !currentSelection!.isEmpty {
                let cfg = SettingsManager.shared.settings.translation
                if cfg.enabled && !cfg.apiKey.isEmpty {
                    toolbarDidSelectTranslate()
                    return true
                }
            }

        case 0, 14: // A or E (Annotate)
            if !isCmd && currentSelection != nil && !currentSelection!.isEmpty {
                toolbarDidSelectAnnotate()
                return true
            }

        case 6 where isCmd: // ⌘Z (Undo) or ⌘⇧Z (Redo)
            if isShift {
                toolbarDidRedo()
            } else {
                toolbarDidUndo()
            }
            return true

        default:
            break
        }

        return false
    }

    func closeOverlay(restoreFocus: Bool = true) {
        removeKeyMonitor()
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        hideToolbar()
        capturedFrames.removeAll()
        currentSelection = nil
        NSCursor.arrow.set()
        // 截图结束把前台还给用户 —— 让他的浮动面板自动回来。
        // 少数路径（保存面板 / 翻译面板要用户继续交互）会传 false 保留焦点。
        if restoreFocus { restoreUserFocus() }
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        let panel = OverlayWindowPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false

        let canvasView = OverlayCanvasView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            screen: screen,
            manager: self
        )
        panel.contentView = canvasView

        return panel
    }

    // MARK: - Synchronized Redraw across all screens
    func updateSelection(_ rect: SelectionRect?) {
        self.currentSelection = rect
        for window in overlayWindows {
            window.contentView?.needsDisplay = true
        }

        if let rect = rect, !rect.isEmpty {
            showToolbar(near: rect.standardized)
        } else {
            hideToolbar()
        }
    }

    // MARK: - Floating Toolbar

    /// 请求在选区附近显示工具条。
    ///
    /// **不再在这里同步做布局**：只记下选区，真正的「测尺寸 + 摆位置 + 解算约束」
    /// 合并到本 runloop 尾巴上执行（`scheduleToolbarUpdate`）。拖动选区时这个方法
    /// 每帧都会被调用，同步布局既浪费又正好落在崩溃路径上。
    func showToolbar(near selectionRect: CGRect) {
        let standardized = selectionRect.standardized
        if pendingToolbarSelection != standardized {
            toolbarPass = 0   // 新的摆放请求：重置补拍预算
        }
        pendingToolbarSelection = standardized
        scheduleToolbarUpdate()
    }

    func hideToolbar() {
        toolbarPanel?.orderOut(nil)
        pendingToolbarSelection = nil
        lastToolbarFrame = nil
        toolbarPass = 0
    }

    /// 合并密集调用：一个 runloop 内最多执行一次摆放。
    private func scheduleToolbarUpdate() {
        guard !toolbarUpdateScheduled else { return }
        toolbarUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.toolbarUpdateScheduled = false
            self.applyToolbarUpdate()
        }
    }

    private func applyToolbarUpdate() {
        guard let selection = pendingToolbarSelection, !selection.isEmpty else { return }
        guard let panel = ensureToolbarPanel(), let hosting = toolbarHosting else { return }

        syncToolbarModel()
        // 先让 SwiftUI 把状态变更落地，否则拟合出来的还是上一版尺寸
        //（展开 / 收起标注栏时高度会变）。
        hosting.layoutSubtreeIfNeeded()

        let size = measuredToolbarSize(hosting: hosting)
        let target = toolbarFrame(for: selection, size: size)

        if lastToolbarFrame != target {
            lastToolbarFrame = target
            panel.setFrame(target, display: false)
        }
        if !panel.isVisible {
            // 不抢 key：工具条只用鼠标，键盘焦点要留给截图遮罩。
            panel.orderFrontRegardless()
        }

        // ⚠️ 关键防御：把约束解算显式压进当前调用栈，并用 ObjC @try/@catch 兜住。
        // 若不主动解算，异常会在 CA transaction commit 时才冒出来，
        // AppKit 直接走 _crashOnException → SIGTRAP，进程没法自救。
        if CrashGuard.run("toolbarLayout", {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }) != nil {
            handleToolbarLayoutFailure()
            return
        }

        // 尺寸还在变（刚切换标注栏）→ 补一轮，最多 3 轮，防止无限补拍。
        let settled = measuredToolbarSize(hosting: hosting)
        if settled != size, toolbarPass < 3 {
            toolbarPass += 1
            scheduleToolbarUpdate()
        }
    }

    @discardableResult
    private func ensureToolbarPanel() -> FloatingToolbarPanel? {
        if let panel = toolbarPanel, toolbarHosting != nil { return panel }
        // 连续异常超过上限就别再硬撑了：截图主流程仍然可用，只是不显示工具条。
        guard toolbarRecoveryCount <= 5 else { return nil }

        let hosting = NSHostingView(rootView: FloatingToolbarView(delegate: self, model: toolbarModel))
        hosting.autoresizingMask = [.width, .height]
        let panel = FloatingToolbarPanel(contentView: hosting)
        toolbarPanel = panel
        toolbarHosting = hosting
        lastToolbarFrame = nil
        SnipLog.write("Toolbar: 面板已创建（单实例复用）")
        return panel
    }

    /// 把 manager 的当前状态灌进工具条模型（值相同就不发布，避免无谓重绘）。
    private func syncToolbarModel() {
        let cfg = SettingsManager.shared.settings.translation
        let translationAvailable = cfg.enabled && !cfg.apiKey.isEmpty
        if toolbarModel.translationAvailable != translationAvailable {
            toolbarModel.translationAvailable = translationAvailable
        }
        if toolbarModel.isAnnotating != isAnnotating { toolbarModel.isAnnotating = isAnnotating }
        if toolbarModel.selectedTool != activeTool { toolbarModel.selectedTool = activeTool }
        if toolbarModel.selectedColor != activeColor { toolbarModel.selectedColor = activeColor }
        if toolbarModel.strokeWidth != activeStrokeWidth { toolbarModel.strokeWidth = activeStrokeWidth }
    }

    private func measuredToolbarSize(hosting: NSHostingView<FloatingToolbarView>) -> CGSize {
        var size = hosting.fittingSize
        if !size.width.isFinite || size.width < 1 { size.width = 360 }
        if !size.height.isFinite || size.height < 1 { size.height = 48 }
        // 兜底上限：拟合值一旦荒唐（曾出现 0 或超大），宁可退回一个保守尺寸，
        // 也不要把窗口撑成异常几何再交给约束系统。
        size.width = min(max(size.width, 320), 900)
        size.height = min(max(size.height, 36), 320)
        return size
    }

    /// 按选区摆放工具条：默认在选区下方，贴边则翻到上方，并整体收进屏幕。
    private func toolbarFrame(for selection: CGRect, size: CGSize) -> CGRect {
        let margin: CGFloat = 10
        let screen = NSScreen.screens.first { $0.frame.intersects(selection) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        var x = selection.maxX - size.width
        var y = selection.minY - size.height - margin
        if y < screen.minY { y = selection.maxY + margin }        // 下方放不下 → 翻到上方

        if x + size.width > screen.maxX { x = screen.maxX - size.width }
        if x < screen.minX { x = screen.minX }
        if y + size.height > screen.maxY { y = screen.maxY - size.height }
        if y < screen.minY { y = screen.minY }

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 约束解算抛异常后的自救：整个面板扔掉重建（带异常状态的约束树不可信），
    /// 但截图 / 键盘快捷键等主流程不受影响。
    private func handleToolbarLayoutFailure() {
        toolbarRecoveryCount += 1
        SnipLog.write("Toolbar: ⚠️ 约束解算异常已拦截 → 重建面板（连续第 \(toolbarRecoveryCount) 次）")

        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        toolbarHosting = nil
        lastToolbarFrame = nil
        toolbarPass = 0

        guard toolbarRecoveryCount <= 5, let selection = pendingToolbarSelection, !selection.isEmpty else {
            SnipLog.write("Toolbar: 连续异常达上限，本次不再显示工具条（截图流程照常可用）")
            return
        }
        // 延后一拍重建：不要在异常现场继续布局。
        DispatchQueue.main.async { [weak self] in
            self?.showToolbar(near: selection)
        }
    }

    // MARK: - FloatingToolbarDelegate
    func toolbarDidSelectPin() {
        guard let finalImage = createFinalRenderedImage() else { return }
        let origin = currentSelection?.standardized.origin
        closeOverlay()
        PinWindowManager.shared.createPin(image: finalImage, at: origin)
    }

    func toolbarDidSelectAnnotate() {
        isAnnotating.toggle()
        activeTool = isAnnotating ? .rectangle : .select
        // 状态同步给工具条模型（视图自己已经翻过 isAnnotating，这里保持一致）
        toolbarModel.isAnnotating = isAnnotating
        toolbarModel.selectedTool = activeTool
        if let sel = currentSelection {
            showToolbar(near: sel.standardized)
        }
    }

    func toolbarDidSelectCopy() {
        guard let finalImage = createFinalRenderedImage() else { return }
        PasteboardService.shared.copyImage(finalImage)
        SoundService.shared.playCaptureSound()
        closeOverlay()
    }

    func toolbarDidSelectSave() {
        guard let finalImage = createFinalRenderedImage() else { return }
        // 保存面板是本 App 的窗口，需要保持前台；等用户选完路径再归还焦点。
        closeOverlay(restoreFocus: false)
        // NSSavePanel 只有在 App 是活跃应用时才能正常交互（遮罩走 nonactivating
        // 方案后，此时前台还是用户的 App），所以这里必须显式激活一次。
        // 这正是用户主动选择「保存」的场景，激活是预期行为。
        NSApp.activate(ignoringOtherApps: true)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "SnipShot_\(Int(Date().timeIntervalSince1970)).png"

        savePanel.begin { [weak self] response in
            if response == .OK, let url = savePanel.url {
                if let tiff = finalImage.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: url)
                }
            }
            Task { @MainActor in self?.restoreUserFocus() }
        }
    }

    func toolbarDidSelectTranslate() {
        guard let finalImage = createFinalRenderedImage() else { return }
        let config = SettingsManager.shared.settings.translation
        guard config.enabled else {
            NSSound.beep()
            return
        }
        // 先把选区存下来：closeOverlay() 会清空 currentSelection。
        let selection = currentSelection?.standardized

        // 用户要求「不要黑色遮罩，正常 UI 显示」：
        // 翻译前直接退出截图模式（遮罩/暗化/鼠标键盘拦截一起消失），
        // 屏幕回到正常亮度，翻译面板作为普通浮窗显示在正常界面上。
        // 截图内容不会丢 —— 缩略图带在翻译面板顶部，可随时复制。
        // 这一步保留焦点（面板马上要显示、要能选中文字），翻译面板关闭后再归还。
        closeOverlay(restoreFocus: false)

        TranslationFlow.shared.run(image: finalImage,
                                   config: config,
                                   avoiding: selection)
    }

    func toolbarDidSelectClose() {
        closeOverlay()
    }

    func toolbarDidChangeTool(_ tool: AnnotationToolType) {
        activeTool = tool
        toolbarModel.selectedTool = tool
    }

    func toolbarDidChangeColor(_ color: ColorRepresentation) {
        activeColor = color
        toolbarModel.selectedColor = color
    }

    func toolbarDidChangeStrokeWidth(_ width: CGFloat) {
        activeStrokeWidth = width
        toolbarModel.strokeWidth = width
    }

    // MARK: - Scroll-wheel helpers (called by OverlayCanvasView.scrollWheel)

    /// Adjusts current active stroke width by `delta`, clamped to [minWidth, maxWidth]; refreshes toolbar UI.
    func adjustActiveStrokeWidth(by delta: CGFloat, minWidth: CGFloat = 1, maxWidth: CGFloat = 48) {
        let lowerBound = Swift.min(minWidth, maxWidth)
        let upperBound = Swift.max(minWidth, maxWidth)
        let candidate = Swift.max(lowerBound, Swift.min(upperBound, activeStrokeWidth + delta))
        let snapped = (candidate * 10).rounded() / 10  // round to 0.1
        guard snapped != activeStrokeWidth else { return }
        activeStrokeWidth = snapped
        toolbarModel.strokeWidth = snapped
        // Refresh toolbar to reflect the new picker value
        if let sel = currentSelection {
            showToolbar(near: sel.standardized)
        }
    }

    /// Rescales the active selection rectangle by `factor` around an anchor point.
    /// No-op when factor == 1 or selection is empty.
    func scaleSelection(_ selection: SelectionRect, factor: CGFloat, anchor: CGPoint) {
        guard factor != 1.0 else { return }
        let std = selection.standardized
        guard std.width > 1, std.height > 1 else { return }
        let newW = max(20, min(6000, std.width * factor))
        let newH = max(20, min(6000, std.height * factor))
        let realFactorW = newW / std.width
        let realFactorH = newH / std.height
        let newX = anchor.x - (anchor.x - std.origin.x) * realFactorW
        let newY = anchor.y - (anchor.y - std.origin.y) * realFactorH
        let scaled = SelectionRect(x: newX, y: newY, width: newW, height: newH)
        updateSelection(scaled)
    }

    func toolbarDidUndo() {
        if let prevDoc = history.undo() {
            annotationDoc = prevDoc
            for window in overlayWindows {
                window.contentView?.needsDisplay = true
            }
        }
    }

    func toolbarDidRedo() {
        if let nextDoc = history.redo() {
            annotationDoc = nextDoc
            for window in overlayWindows {
                window.contentView?.needsDisplay = true
            }
        }
    }

    func pushAnnotationHistory() {
        history.push(annotationDoc)
    }

    private func createFinalRenderedImage() -> NSImage? {
        guard let selection = currentSelection?.standardized,
              let baseCropped = CaptureService.shared.cropSelection(rect: selection, from: capturedFrames) else {
            return nil
        }

        // Adjust annotation coordinates relative to selection origin
        var relativeDoc = AnnotationDocument()
        for item in annotationDoc.items {
            var relItem = item
            relItem.startPoint = CGPoint(
                x: item.startPoint.x - selection.origin.x,
                y: item.startPoint.y - selection.origin.y
            )
            relItem.endPoint = CGPoint(
                x: item.endPoint.x - selection.origin.x,
                y: item.endPoint.y - selection.origin.y
            )
            relItem.points = item.points.map {
                CGPoint(x: $0.x - selection.origin.x, y: $0.y - selection.origin.y)
            }
            relativeDoc.items.append(relItem)
        }

        return AnnotationRenderer.render(document: relativeDoc, onto: baseCropped)
    }
}

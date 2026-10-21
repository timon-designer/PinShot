import Cocoa
import SwiftUI
import PinShotCore

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var placementAttempts = 0

    func setupMenuBar() {
        guard statusItem == nil else { return }
        buildStatusItem()
    }

    // MARK: - 图标

    /// 代码绘制的模板图（取景框 + 中心点）。
    /// 不用 SF Symbol：`NSImage(systemSymbolName:)` 取不到时会得到一个
    /// 「空白但仍占位」的菜单栏项，肉眼看上去就是"图标没出来"，很难排查。
    /// 模板图系统只看 alpha 通道，so 黑色 = 不透明，自动适配深浅色菜单栏。
    private func makeIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let inset: CGFloat = 1.8
            let arm: CGFloat = 4.2
            let minX = rect.minX + inset, maxX = rect.maxX - inset
            let minY = rect.minY + inset, maxY = rect.maxY - inset

            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // 左上角
            path.move(to: NSPoint(x: minX, y: maxY - arm))
            path.line(to: NSPoint(x: minX, y: maxY))
            path.line(to: NSPoint(x: minX + arm, y: maxY))
            // 右上角
            path.move(to: NSPoint(x: maxX - arm, y: maxY))
            path.line(to: NSPoint(x: maxX, y: maxY))
            path.line(to: NSPoint(x: maxX, y: maxY - arm))
            // 右下角
            path.move(to: NSPoint(x: maxX, y: minY + arm))
            path.line(to: NSPoint(x: maxX, y: minY))
            path.line(to: NSPoint(x: maxX - arm, y: minY))
            // 左下角
            path.move(to: NSPoint(x: minX + arm, y: minY))
            path.line(to: NSPoint(x: minX, y: minY))
            path.line(to: NSPoint(x: minX, y: minY + arm))
            path.stroke()

            // 中心点
            NSBezierPath(
                ovalIn: NSRect(x: rect.midX - 1.9, y: rect.midY - 1.9, width: 3.8, height: 3.8)
            ).fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - 状态栏项目

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = makeIcon()
            button.toolTip = "SnipShot — 点开菜单 / ⌘⇧A 截图"
        }
        item.menu = buildMenu()
        statusItem = item

        let frame = item.button?.window?.frame ?? .zero
        SnipLog.write("菜单栏: 已创建 statusItem frame=\(NSStringFromRect(frame))")

        // macOS 26 有时会把新建的状态栏项直接丢到屏幕外（y 为负），
        // 肉眼完全看不到。0.8s 后校验一次真实落位，没贴上就重建。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.verifyPlacement()
        }
    }

    private func verifyPlacement() {
        guard let item = statusItem, let button = item.button else { return }
        let frame = button.window?.frame ?? .zero

        if Self.isPlacedInMenuBar(button) {
            SnipLog.write("菜单栏: ✅ 已贴在菜单栏上 frame=\(NSStringFromRect(frame))")
            placementAttempts = 0
            return
        }

        SnipLog.write("菜单栏: ⚠️ 未贴上 frame=\(NSStringFromRect(frame)) visible=\(item.isVisible)")

        guard placementAttempts < 3 else {
            SnipLog.write("""
            菜单栏: ❌ 重建 3 次仍无法贴上。
            这是 macOS 26 的已知行为：系统会**按 CFBundleIdentifier 持久记住
            「这个 App 的菜单栏项目被隐藏」**，一旦该 id 被污染，同 id 的任何
            二进制都显示不出来（代码怎么写都没用）。
            解法：换一个新的 CFBundleIdentifier（run-local.sh 里的 BUNDLE_ID）。
            """)
            return
        }

        placementAttempts += 1
        SnipLog.write("菜单栏: 重建第 \(placementAttempts) 次")
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        buildStatusItem()
    }

    /// 判断状态栏按钮是否真的落在菜单栏里（贴顶）。
    private static func isPlacedInMenuBar(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window, let screen = NSScreen.main else { return false }
        let frame = window.frame
        return frame.width >= 8 && frame.maxY >= screen.frame.maxY - 2
    }

    // MARK: - 菜单

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 区域截图
        let captureItem = NSMenuItem(
            title: "区域截图",
            action: #selector(captureAreaAction),
            keyEquivalent: "a"
        )
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(NSMenuItem.separator())

        // 当前贴图
        let pinsMenu = NSMenu()
        let pinsMenuItem = NSMenuItem(title: "当前贴图", action: nil, keyEquivalent: "")
        pinsMenuItem.submenu = pinsMenu
        menu.addItem(pinsMenuItem)

        // 关闭全部贴图
        let closeAllItem = NSMenuItem(
            title: "关闭全部贴图",
            action: #selector(closeAllPinsAction),
            keyEquivalent: ""
        )
        closeAllItem.target = self
        menu.addItem(closeAllItem)

        menu.addItem(NSMenuItem.separator())

        // 偏好设置
        let settingsItem = NSMenuItem(
            title: "偏好设置…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 检查权限
        let permissionItem = NSMenuItem(
            title: "检查权限…",
            action: #selector(openPermissionsAction),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        // 热键自检 —— 直接显示当前热键注册状态，省得猜
        let hotkeyStatusItem = NSMenuItem(
            title: "热键状态：\(HotKeyService.shared.statusDescription)",
            action: nil,
            keyEquivalent: ""
        )
        hotkeyStatusItem.isEnabled = false
        menu.addItem(hotkeyStatusItem)

        // 重新注册热键
        let reRegisterItem = NSMenuItem(
            title: "重新注册热键",
            action: #selector(reRegisterHotKeyAction),
            keyEquivalent: ""
        )
        reRegisterItem.target = self
        menu.addItem(reRegisterItem)

        menu.addItem(NSMenuItem.separator())

        // 关于 —— macOS 上「看应用图标 + 版本」的标准位置。
        // 标准关于面板会把应用图标放大展示（读的就是 NSApp.applicationIconImage）。
        let aboutItem = NSMenuItem(
            title: "关于 SnipShot",
            action: #selector(showAboutAction),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        // 退出
        let quitItem = NSMenuItem(
            title: "退出 SnipShot",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        return menu
    }

    @objc private func captureAreaAction() {
        OverlayWindowManager.shared.startCapture()
    }

    @objc private func closeAllPinsAction() {
        PinWindowManager.shared.closeAllPins()
    }

    @objc private func openSettingsAction() {
        SettingsWindowManager.shared.show()
    }

    @objc private func openPermissionsAction() {
        PermissionWindowManager.shared.show {
            // Permission granted
        }
    }

    @objc private func reRegisterHotKeyAction() {
        let ok = HotKeyService.shared.reloadHotKey()
        SnipLog.write("菜单: 手动重新注册热键 → \(ok ? "成功" : "失败")")
        if !ok {
            let alert = NSAlert()
            alert.messageText = "热键注册失败"
            alert.informativeText = """
            \(HotKeyService.shared.statusDescription)

            如果提示「被其他 App 占用」，说明该组合已被别的软件抢注（例如微信/企业微信的 \
            默认截图键就是 ⌘⇧A）。请到「偏好设置 → 快捷键」换一个组合。
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "去偏好设置")
            alert.addButton(withTitle: "知道了")
            if alert.runModal() == .alertFirstButtonReturn {
                SettingsWindowManager.shared.show()
            }
        }
    }

    @objc private func showAboutAction() {
        // 面板里的图标来自 NSApp.applicationIconImage（AppDelegate 启动时已赋值）。
        // 未赋值时显示通用「应用」图标 —— 所以这行同时也是一个图标是否接好的自检点。
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        // LSUIElement（无 Dock 图标）的 App 弹面板前必须先激活，否则面板会藏在后面
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "SnipShot",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: "截图 · 贴图 · 翻译\n⌘⇧A 开始截图",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    /// 每次展开菜单都刷新热键状态行，保证显示的是当前真实状态
    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items where item.title.hasPrefix("热键状态：") {
            item.title = "热键状态：\(HotKeyService.shared.statusDescription)"
        }
    }
}

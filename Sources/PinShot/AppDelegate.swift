import Cocoa
import PinShotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var servicesReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SnipLog.reset()
        SnipLog.write("=== SnipShot 启动 (PID \(ProcessInfo.processInfo.processIdentifier)) ===")

        // 异常兜底要在任何 UI 之前装好：
        // 1. 把上一次进程的异常记录（如果有）抄进本次日志；
        // 2. 注册未捕获异常处理器，崩溃时留下可复现的堆栈证据。
        CrashGuard.installUncaughtExceptionHandler()

        // Run as menu bar accessory app (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        // 把 bundle 里的 AppIcon.icns 显式交给 NSApp。
        // 系统界面（访达/启动台）看的是 bundle 图标，但「关于面板」和任何
        // 读 applicationIconImage 的地方看的是这个属性 —— 不赋值就会显示通用图标。
        if let icon = AppIconProvider.image {
            NSApp.applicationIconImage = icon
            SnipLog.write("应用图标: 已加载 \(NSStringFromSize(icon.size))")
        } else {
            SnipLog.write("应用图标: ⚠️ 未找到 AppIcon.icns（图标可能不显示）")
        }

        // Setup Menu Bar Item
        MenuBarController.shared.setupMenuBar()
        SnipLog.write("菜单栏图标已创建")

        // 关键：全局热键必须无条件注册。
        // Carbon 的 RegisterEventHotKey 不需要屏幕录制权限 —— 之前把它放在权限判断的
        // else 分支里，导致「权限没给 = 热键也不注册 = 用户怎么按都没反应」。
        // 正确做法：热键先注册，按下去之后再由 startCapture() 去检查权限。
        setupServices()

        // 权限检查只决定要不要给用户看引导窗口，不影响热键
        if PermissionService.shared.checkPermission() {
            SnipLog.write("屏幕录制权限: 已授予 ✅")
        } else {
            SnipLog.write("屏幕录制权限: 未授予 → 注册到系统列表 + 弹引导窗口")
            // 主动触发一次系统请求。目的有两个：
            //  1. 让 macOS 弹出「SnipShot 想要录制此电脑的屏幕」系统提示
            //  2. 把 SnipShot 写进 系统设置 → 隐私与安全性 → 屏幕录制 的列表
            // 不主动请求的话，用户在那个列表里可能根本找不到这个 App（踩过坑）。
            PermissionService.shared.requestPermission()

            PermissionWindowManager.shared.show { [weak self] in
                guard let self = self else { return }
                SnipLog.write("权限已授予 → 自动重启 SnipShot 使权限生效")
                self.setupServices()
                // 屏幕录制权限有一个系统级特性：**在同一个进程里新授予的权限通常不会
                // 立即生效**（CGPreflight 已经返回 true，但抓屏拿到的还是黑屏/桌面）。
                // 官方推荐的解法就是退出重开，所以这里自动重启一次，省得用户以为没生效。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    PermissionService.shared.relaunchApp()
                }
            }
        }
    }

    private func setupServices() {
        // 必须走 registerDefaultHotKey —— 它会把「按下热键后要做什么」这个回调存进去。
        // 之前这里只调用了 reloadHotKey()，热键注册成功但回调始终是 nil，
        // 于是「按下 ⌘⇧A 完全没反应」。两者缺一不可：
        //   registerDefaultHotKey = 存回调 + 注册
        //   reloadHotKey          = 只重新注册（比如用户改了快捷键）
        let ok = HotKeyService.shared.registerDefaultHotKey {
            OverlayWindowManager.shared.startCapture()
        }
        SnipLog.write("热键注册结果: \(ok ? "成功" : "失败") — \(HotKeyService.shared.statusDescription)")
    }
}

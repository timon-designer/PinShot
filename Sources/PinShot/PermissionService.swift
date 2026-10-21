import Cocoa
import CoreGraphics
@preconcurrency import ScreenCaptureKit

@MainActor
final class PermissionService: ObservableObject {
    static let shared = PermissionService()

    @Published var hasScreenRecordingPermission: Bool = false
    private var timer: Timer?

    init() {
        checkPermission()
    }

    /// Checks if screen recording permission is currently granted.
    @discardableResult
    func checkPermission() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        self.hasScreenRecordingPermission = granted
        return granted
    }

    /// Actively triggers the macOS system dialog & registers PinShot in System Settings (TCC).
    func requestPermission() {
        // 1. CGRequestScreenCaptureAccess (macOS legacy / standard TCC prompt)
        CGRequestScreenCaptureAccess()

        // 2. Modern ScreenCaptureKit attempt - this forces macOS 14/15/16 to show
        // "PinShot would like to record this computer's screen" and adds it to the list in Settings.
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let display = content.displays.first {
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = 64
                    config.height = 64
                    _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                }
            } catch {
                // Throws if permission is denied/not yet granted, but the attempt itself registers the app in TCC.
            }
        }

        // 3. Fallback display capture to touch CG display
        _ = CGDisplayCreateImage(CGMainDisplayID())

        startPolling()
    }

    /// Opens macOS System Settings directly to Privacy & Security -> Screen Recording.
    func openSystemSettings() {
        requestPermission()

        // macOS 15+ 起，隐私设置面板换了 scheme。旧 scheme 在部分版本上会打开「通用」页面，
        // 而不是屏幕录制列表，所以优先用新 scheme，失败再退回旧的。
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { break }
        }
        startPolling()
    }

    /// Starts polling in the background so when the user toggles permission in Settings,
    /// the app notices immediately without requiring a full manual relaunch.
    ///
    /// 注意：用 `Timer` 手动加进 `.common` runloop mode。
    /// 默认的 `scheduledTimer` 只挂在 `.default` mode —— 一旦有菜单弹出、
    /// 窗口拖拽或 modal 循环，runloop 切到别的 mode，轮询就静默停摆，
    /// 表现正是「我明明开了权限，它还是说没开」。
    func startPolling(onGranted: (@MainActor () -> Void)? = nil) {
        timer?.invalidate()
        // 存到 MainActor 隔离的属性，避免把闭包直接捕获进 @Sendable 的 Timer 回调
        self.onGrantedCallback = onGranted
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.checkPermission() {
                    SnipLog.write("轮询: 检测到屏幕录制权限已授予 ✅")
                    self.stopPolling()
                    let cb = self.onGrantedCallback
                    self.onGrantedCallback = nil
                    cb?()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 保存回调，便于外部（如手动点「重新检查」）复用
    private var onGrantedCallback: (@MainActor () -> Void)?

    /// 手动触发一次检查；若已授权则执行回调。
    @discardableResult
    func checkAndNotify() -> Bool {
        if checkPermission() {
            stopPolling()
            let cb = onGrantedCallback
            onGrantedCallback = nil
            cb?()
            return true
        }
        return false
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// macOS 对「屏幕录制」权限有个系统级限制：**权限变更后，当前进程不一定能立即生效**
    /// （CGPreflight 可能已返回 true，但 ScreenCaptureKit 抓屏仍失败或抓到黑屏）。
    /// 最可靠的解法是拿到权限后把 App 重启一次。
    func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

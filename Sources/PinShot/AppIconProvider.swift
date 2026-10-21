import AppKit

/// 应用图标（`Resources/AppIcon.icns` → `Contents/Resources/AppIcon.icns`）的统一入口。
///
/// 为什么需要 Swift 侧再包一层？因为 macOS 的 bundle 图标**只对系统界面生效**
/// （访达、启动台、系统设置里那个列表、切换器），App **自己画的界面**是拿不到的 ——
/// 权限引导页头部、关于面板都得显式去读。不读就会出现「访达里图标好好的，
/// App 打开的窗口里却是空白/占位图」这种看起来像 bug 的现象。
enum AppIconProvider {

    /// 当前 App 的图标；取不到返回 nil。
    static let image: NSImage? = load()

    private static func load() -> NSImage? {
        // 1) 最准的来源：bundle 里的 .icns 本体（就是 CFBundleIconFile 指的那个文件）
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        // 2) 系统已解析好的图标（正常情况下由 CFBundleIconFile 得到）
        if let icon = NSApplication.shared.applicationIconImage {
            return icon
        }
        // 3) 开发期兜底：`swift run` / `swift test` 时没有 .app bundle，
        //    按源码路径回溯到项目的 Resources/。仅调试用，正式包里走不到这里。
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PinShot/
            .deletingLastPathComponent()      // Sources/
            .deletingLastPathComponent()      // 项目根
        let fallback = sourceDir.appendingPathComponent("Resources/AppIcon.icns")
        if FileManager.default.fileExists(atPath: fallback.path),
           let icon = NSImage(contentsOf: fallback) {
            return icon
        }
        return nil
    }
}

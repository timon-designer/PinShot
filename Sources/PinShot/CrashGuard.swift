import Cocoa
import PSExceptionGuard

/// 未捕获异常的「黑匣子」路径：崩溃时同步落盘，下次启动时抄进 /tmp/snipshot.log。
/// 用文件级常量而不是 `CrashGuard.xxx`，因为 `NSSetUncaughtExceptionHandler`
/// 需要 C 函数指针，闭包里不能捕获任何上下文（含访问类型元数据）。
private let snipExceptionMarkerPath = "/tmp/snipshot.last-exception"

/// 异常兜底工具。
///
/// 背景（见 TASK-current.md）：PinShot 的两次闪退都是
/// `EXC_BREAKPOINT / +[NSApplication _crashOnException:]`，
/// 栈在 `CA::Transaction::flush → updateConstraintsIfNeeded → _NSViewUpdateConstraints_block_invoke`
/// —— 也就是 **AutoLayout 约束解算期间抛出了未捕获的 NSException**，
/// AppKit 把这个异常当成「程序有 bug」直接 SIGTRAP 杀掉进程。
///
/// 两层兜底：
/// 1. `run(_:_:)` 把可能抛异常的布局代码包进 ObjC `@try/@catch`（进程不死，事后重建 UI）；
/// 2. `installUncaughtExceptionHandler()` 兜住其它路径的未捕获异常并留下证据。
enum CrashGuard {

    /// 未捕获异常记录文件。为什么不用 DispatchQueue：崩溃路径上异步任务可能
    /// 永远排不到，必须同步写。
    static let exceptionMarkerPath = snipExceptionMarkerPath

    /// 把一段代码包进 ObjC @try/@catch。
    /// - Returns: 捕获到的异常描述；`nil` 表示正常执行完。
    @discardableResult
    static func run(_ label: String, _ body: () -> Void) -> String? {
        let reason = ps_runCatchingException(body)
        guard let reason else { return nil }
        SnipLog.write("⚠️ [\(label)] 已拦截 ObjC 异常（进程存活）：\(reason)")
        appendRecord(label: label, reason: reason)
        return reason
    }

    /// 安装未捕获异常处理器，并把上次的异常记录带进本次日志。
    static func installUncaughtExceptionHandler() {
        if let previous = try? String(contentsOfFile: exceptionMarkerPath, encoding: .utf8),
           !previous.isEmpty {
            SnipLog.write("⚠️ 上一次运行异常退出，记录如下：\n\(previous)")
            try? FileManager.default.removeItem(atPath: exceptionMarkerPath)
        }

        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let symbols = exception.callStackSymbols.prefix(24).joined(separator: "\n")
            let text = "时间: \(Date())\n\(name): \(reason)\n\(symbols)\n"
            try? text.write(toFile: snipExceptionMarkerPath, atomically: true, encoding: .utf8)
        }
    }

    private static func appendRecord(label: String, reason: String) {
        let line = "时间: \(Date())\n拦截点: \(label)\n\(reason)\n\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: exceptionMarkerPath)) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(toFile: exceptionMarkerPath, atomically: true, encoding: .utf8)
        }
    }
}

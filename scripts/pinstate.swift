import Cocoa

// 输出 SnipShot 的「贴图窗」(layer 3, onscreen) 数值状态: X Y W H
func pinBounds() -> (x: Double, y: Double, w: Double, h: Double)? {
    guard let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.timon.snipshot" }) else { return nil }
    let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for i in infos {
        guard let p = i[kCGWindowOwnerPID as String] as? Int, p == Int(a.processIdentifier) else { continue }
        let layer = (i[kCGWindowLayer as String] as? Int) ?? -1
        let on = (i[kCGWindowIsOnscreen as String] as? Bool) ?? false
        guard layer == 3, on else { continue }
        let b = i[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return (b["X"] as? Double ?? 0, b["Y"] as? Double ?? 0, b["Width"] as? Double ?? 0, b["Height"] as? Double ?? 0)
    }
    return nil
}
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(22_000) }

/// 合成 ⌘⇧A 之后系统会一直认为 ⌘/⇧ 还按着（我们没发对应的 flagsChanged），
/// 后续所有事件的修饰键都被污染 —— 实测会让滚轮被系统转成横向滚动。
/// 每次动作前显式发一个空 flags 的 flagsChanged 把状态清干净。
func clearMods() {
    if let e = CGEvent(source: nil) {
        e.type = .flagsChanged
        e.flags = []
        e.post(tap: .cghidEventTap)
    }
    usleep(60_000)
}
func move(_ p: CGPoint) { post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)) }

let a = Array(CommandLine.arguments.dropFirst())
guard let cmd = a.first else { print("usage"); exit(2) }
func n(_ i: Int) -> Double { Double(a[i])! }

switch cmd {
case "pin":
    if let b = pinBounds() { print(String(format: "%.0f %.0f %.0f %.0f", b.x, b.y, b.w, b.h)) }
    else { print("NONE") }

case "drag":   // x1 y1 x2 y2 steps
    clearMods()
    let p0 = CGPoint(x: n(1), y: n(2)), p1 = CGPoint(x: n(3), y: n(4))
    let steps = a.count > 5 ? Int(a[5])! : 20
    move(p0); usleep(120_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p0, mouseButton: .left))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                     mouseCursorPosition: CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t),
                     mouseButton: .left))
        usleep(11_000)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p1, mouseButton: .left))
    print("dragged")

case "scroll": // x y deltaLines [opt|shift]
    clearMods()
    let p = CGPoint(x: n(1), y: n(2)); let dy = Int32(n(3))
    var flags: CGEventFlags = []
    let modName = a.count > 4 ? a[4] : "none"
    if modName == "opt" { flags = .maskAlternate }
    if modName == "shift" { flags = .maskShift }
    move(p); usleep(200_000)
    let cur = NSEvent.mouseLocation
    let curCG = CGPoint(x: cur.x, y: (NSScreen.main?.frame.height ?? 982) - cur.y)
    print(String(format: "  [harness] 目标(%.0f,%.0f) 实际光标(%.0f,%.0f) mod=%@", p.x, p.y, curCG.x, curCG.y, modName))
    var sent = 0
    for _ in 0..<5 {
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) {
            e.flags = []
            e.location = p
            // 用 insert 而不是整体赋值：整体赋值会清掉滚动事件需要的其他标志位，
            // 实测 `e.flags = .maskShift` 会让事件直接不被派发（scrollWheel 一次都不触发）。
            if !flags.isEmpty { e.flags.insert(flags) }
            e.post(tap: .cghidEventTap); sent += 1
        }
        usleep(60_000)
    }
    print("  [harness] 已发 \(sent) 个滚轮事件 dy=\(dy)")

case "hotkey":
    let src = CGEventSource(stateID: .hidSystemState)
    let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!; d.flags = [.maskCommand, .maskShift]
    let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!; u.flags = [.maskCommand, .maskShift]
    post(d); usleep(60_000); post(u); print("⌘⇧A")

case "key":
    let src = CGEventSource(stateID: .hidSystemState)
    let k = CGKeyCode(n(1))
    post(CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true)); usleep(40_000)
    post(CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false)); print("key \(k)")

case "dblclick": // x y —— 用真实 clickState=2 触发 SwiftUI 双击手势（回归：拖窗逻辑不能吃掉手势）
    clearMods()
    let p = CGPoint(x: n(1), y: n(2))
    move(p); usleep(200_000)
    for cs in [1, 2] {
        let d = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
        d.setIntegerValueField(.mouseEventClickState, value: Int64(cs))
        d.post(tap: .cghidEventTap); usleep(30_000)
        let u = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!
        u.setIntegerValueField(.mouseEventClickState, value: Int64(cs))
        u.post(tap: .cghidEventTap); usleep(40_000)
    }
    print("dblclick at \(p)")

case "tap": // x y —— 纯点击，**不清修饰键**
    // 为什么需要它：clearMods() 会发一个 flagsChanged 事件，而那个事件会
    // **把已经展开的菜单关掉**。所以「先点开菜单栏 → 再点菜单项」这种两步
    // 操作不能用 drag，必须用 tap。
    let p = CGPoint(x: n(1), y: n(2))
    move(p); usleep(120_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    usleep(60_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
    print("tapped at \(p)")

case "rclick": // x y —— 右键：验证 contextMenu 没被拖窗逻辑打断
    clearMods()
    let p = CGPoint(x: n(1), y: n(2))
    move(p); usleep(200_000)
    let d = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: .right)!
    d.post(tap: .cghidEventTap); usleep(50_000)
    let u = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: .right)!
    u.post(tap: .cghidEventTap)
    print("rclick at \(p)")

case "activate":
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.timon.snipshot" }) {
        app.activate(options: [.activateAllWindows]); print("activated pid=\(app.processIdentifier)")
    } else { print("NOT RUNNING") }

case "deactivate":
    if let f = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
        f.activate(options: []); print("finder activated")
    }

default: print("unknown"); exit(2)
}

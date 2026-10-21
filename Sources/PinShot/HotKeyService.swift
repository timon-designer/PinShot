import Cocoa
import Carbon

@MainActor
final class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    /// 最近一次注册的结果，供 UI 自检展示
    private(set) var lastStatus: OSStatus = -1
    private(set) var lastKeyCode: UInt32 = 0
    private(set) var lastModifiers: UInt32 = 0

    var isRegistered: Bool { hotKeyRef != nil }

    /// 人类可读的状态描述
    var statusDescription: String {
        if isRegistered {
            return "✅ 已注册 \(Self.describe(keyCode: lastKeyCode, modifiers: lastModifiers))"
        }
        if lastStatus == -9878 {
            return "❌ 热键被其他 App 占用（换个组合试试）"
        }
        return "❌ 注册失败 status=\(lastStatus)"
    }

    private init() {}

    /// Registers or updates the global hotkey according to user settings.
    ///
    /// ⚠️ 这是**唯一**会给 `action` 赋值的地方。曾经 AppDelegate 只调用
    /// `reloadHotKey()`，导致热键能触发但 `action == nil`，按下毫无反应。
    /// 现在返回注册结果，方便调用方记录日志。
    @discardableResult
    func registerDefaultHotKey(action: @escaping @MainActor () -> Void) -> Bool {
        self.action = action
        SnipLog.write("HotKey: 截图回调已绑定 (action != nil)")
        return reloadHotKey()
    }

    @discardableResult
    func reloadHotKey() -> Bool {
        unregisterHotKey()

        let settings = SettingsManager.shared.settings
        let keyCode: UInt32 = settings.globalKeyCode
        let modifiers: UInt32 = settings.globalModifiers

        lastKeyCode = keyCode
        lastModifiers = modifiers

        SnipLog.write("HotKey: 注册 \(Self.describe(keyCode: keyCode, modifiers: modifiers)) (keyCode=\(keyCode) mods=0x\(String(modifiers, radix: 16)))")

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x50534854), // 'PSHT'
            id: 1
        )

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerBlock: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                // 注意：这句日志以前写在调用 action 之前，即使 action 为 nil 也会打印
                // 「开始截图流程」，把「没人做事」伪装成「流程已启动」。现在先判空。
                guard let action = service.action else {
                    SnipLog.write("HotKey: 🔔 被触发，但回调是 nil ❌（没人调用 registerDefaultHotKey）")
                    return
                }
                SnipLog.write("HotKey: 🔔 被触发 → 进入截图流程")
                action()
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerBlock,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        lastStatus = status

        if status == noErr {
            SnipLog.write("HotKey: ✅ 注册成功 (handlerStatus=\(handlerStatus))")
        } else if status == -9878 {
            SnipLog.write("HotKey: ❌ 热键已被其他 App 占用 (eventHotKeyExistsErr) — 请在 偏好设置 换个组合")
        } else {
            SnipLog.write("HotKey: ❌ 注册失败 status=\(status) handlerStatus=\(handlerStatus)")
        }

        return status == noErr
    }

    func unregisterHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    /// 把 keyCode + modifiers 翻译成人看的字符串
    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyCodeName(keyCode)
        return s
    }

    static func keyCodeName(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9",
            26: "7", 28: "8", 29: "0",
            96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        ]
        return map[code] ?? "key(\(code))"
    }
}

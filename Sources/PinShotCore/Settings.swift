import Foundation
import CoreGraphics

/// Application configuration and preferences model.
public struct PinShotSettings: Equatable, Sendable, Codable {
    public var globalShortcutName: String
    public var globalKeyCode: UInt32
    public var globalModifiers: UInt32
    public var pinShortcutName: String
    public var copyShortcutName: String
    public var saveShortcutName: String
    public var saveDirectoryPath: String
    public var imageFormat: ImageOutputFormat
    public var toolbarOrientation: ToolbarOrientation
    public var pinShadowStyle: PinShadowStyle
    public var playSoundEffects: Bool
    public var showMagnifierLoupe: Bool
    public var autoCopyToClipboardOnCapture: Bool
    public var translation: TranslationConfig

    public init(
        globalShortcutName: String = "⌘⇧A (Command + Shift + A)",
        globalKeyCode: UInt32 = 0, // 'A' key
        globalModifiers: UInt32 = 0x0100 | 0x0200, // cmdKey | shiftKey
        pinShortcutName: String = "⌘P / P",
        copyShortcutName: String = "⌘C / C",
        saveShortcutName: String = "⌘S / S",
        saveDirectoryPath: String = (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("SnipShot").path) ?? "~/Pictures/SnipShot",
        imageFormat: ImageOutputFormat = .png,
        toolbarOrientation: ToolbarOrientation = .horizontal,
        pinShadowStyle: PinShadowStyle = .nativeOutline,
        playSoundEffects: Bool = true,
        showMagnifierLoupe: Bool = true,
        autoCopyToClipboardOnCapture: Bool = false,
        translation: TranslationConfig = TranslationConfig()
    ) {
        self.globalShortcutName = globalShortcutName
        self.globalKeyCode = globalKeyCode
        self.globalModifiers = globalModifiers
        self.pinShortcutName = pinShortcutName
        self.copyShortcutName = copyShortcutName
        self.saveShortcutName = saveShortcutName
        self.saveDirectoryPath = saveDirectoryPath
        self.imageFormat = imageFormat
        self.toolbarOrientation = toolbarOrientation
        self.pinShadowStyle = pinShadowStyle
        self.playSoundEffects = playSoundEffects
        self.showMagnifierLoupe = showMagnifierLoupe
        self.autoCopyToClipboardOnCapture = autoCopyToClipboardOnCapture
        self.translation = translation
    }
}

/// Configuration for the on-demand translation feature.
///
/// Defaults are a working preset for Zhipu BigModel GLM-4-flash,
/// but every field is user-editable in Settings → Translation.
public struct TranslationConfig: Equatable, Sendable, Codable {
    public var baseURL: String           // e.g. "https://open.bigmodel.cn/api/paas/v4"
    public var modelName: String         // e.g. "glm-4-flash-250414"
    public var apiKey: String            // stored as-is in UserDefaults; for personal use this is OK
    public var systemPrompt: String      // OCR-translate style prompt
    public var targetLanguage: String    // e.g. "Simplified Chinese"
    public var isVisionModel: Bool       // if true, sends image directly; else OCR → text first
    public var enabled: Bool

    public init(
        baseURL: String = "https://open.bigmodel.cn/api/paas/v4",
        // 默认用带日期的快照版本而不是 `glm-4-flash` 这个浮动别名：
        // 同一份 11 行文案实测，别名 4.3~6.3s，快照版只要 1.7~2.4s（同样免费额度）。
        // 别名指向的模型会被服务端悄悄换，速度不可控；快照版行为稳定。
        modelName: String = "glm-4-flash-250414",
        apiKey: String = "",
        systemPrompt: String = "你是一个专业翻译。请将用户提供的文字翻译成{{TARGET}}，只输出译文，不要任何解释、注释或原文重复。",
        targetLanguage: String = "简体中文",
        isVisionModel: Bool = false,
        enabled: Bool = false
    ) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.targetLanguage = targetLanguage
        self.isVisionModel = isVisionModel
        self.enabled = enabled
    }
}

public enum PinShadowStyle: String, CaseIterable, Sendable, Codable {
    case nativeOutline = "Native Accent Outline"
    case classicShadow = "Classic macOS Shadow"
    case minimalBorder = "Minimal White Border"
    case none = "None"

    /// 界面显示用的中文名称（rawValue 保持英文，保证已存配置可正常解码）
    public var displayName: String {
        switch self {
        case .nativeOutline: return "原生强调色描边"
        case .classicShadow: return "经典 macOS 投影"
        case .minimalBorder: return "极简白色边框"
        case .none: return "无"
        }
    }
}

public enum ImageOutputFormat: String, CaseIterable, Sendable, Codable {
    case png = "PNG"
    case jpeg = "JPEG"
    case tiff = "TIFF"
}

public enum ToolbarOrientation: String, CaseIterable, Sendable, Codable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"

    public var displayName: String {
        switch self {
        case .horizontal: return "横向"
        case .vertical: return "纵向"
        }
    }
}

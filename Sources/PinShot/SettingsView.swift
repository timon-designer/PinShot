import SwiftUI
import AppKit
import PinShotCore

struct SettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var selectedTab: SettingsTab = .shortcuts

    enum SettingsTab: String, CaseIterable, Identifiable {
        case shortcuts = "快捷键"
        case general = "通用"
        case output = "输出"
        case translation = "翻译"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .shortcuts: return "keyboard"
            case .general: return "gearshape"
            case .output: return "folder"
            case .translation: return "character.bubble"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab Selector
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Tab Contents
            Group {
                switch selectedTab {
                case .shortcuts:
                    shortcutsTab
                case .general:
                    generalTab
                case .output:
                    outputTab
                case .translation:
                    translationTab
                }
            }
            .padding(24)
            .frame(width: 520, height: 420, alignment: .topLeading)
        }
    }

    // MARK: - 快捷键
    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("键盘快捷键")
                .font(.headline)

            VStack(spacing: 12) {
                // 全局截图
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("区域截图（全局）")
                            .font(.system(size: 13, weight: .medium))
                        Text("在所有显示器上启动全屏截取")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $settingsManager.settings.globalShortcutName) {
                        Text("⌘⇧A").tag("⌘⇧A (Command + Shift + A)")
                        Text("⌥A").tag("⌥A (Option + A)")
                        Text("⌘⇧1").tag("⌘⇧1 (Command + Shift + 1)")
                        Text("F1").tag("F1")
                    }
                    .frame(width: 200)
                    .onChange(of: settingsManager.settings.globalShortcutName) { _, newName in
                        updateGlobalKeyCode(from: newName)
                    }
                }

                Divider()

                // 贴图快捷键
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("将选中区域固定到屏幕")
                            .font(.system(size: 13, weight: .medium))
                        Text("把当前选区变成可悬浮拖拽的贴图")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $settingsManager.settings.pinShortcutName) {
                        Text("⌘P 或 P").tag("⌘P / P")
                        Text("仅 ⌘P").tag("⌘P")
                        Text("仅 P").tag("P")
                    }
                    .frame(width: 140)
                }

                Divider()

                // 复制 / 保存快捷键
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("复制到剪贴板")
                            .font(.system(size: 13, weight: .medium))
                    }
                    Spacer()
                    Text("⌘C / Enter / C")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("保存到文件")
                            .font(.system(size: 13, weight: .medium))
                    }
                    Spacer()
                    Text("⌘S / S")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                }
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
    }

    private func updateGlobalKeyCode(from name: String) {
        if name.contains("⌥A") {
            settingsManager.settings.globalKeyCode = 0 // 'A'
            settingsManager.settings.globalModifiers = 0x0800 // optionKey
        } else if name.contains("⌘⇧1") {
            settingsManager.settings.globalKeyCode = 18 // '1'
            settingsManager.settings.globalModifiers = 0x0100 | 0x0200 // cmdKey | shiftKey
        } else if name.contains("F1") {
            settingsManager.settings.globalKeyCode = 122 // F1
            settingsManager.settings.globalModifiers = 0
        } else {
            // Default ⌘⇧A
            settingsManager.settings.globalKeyCode = 0
            settingsManager.settings.globalModifiers = 0x0100 | 0x0200
        }
        HotKeyService.shared.reloadHotKey()
    }

    // MARK: - 通用
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("通用偏好")
                .font(.headline)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("贴图光晕 / 阴影：")
                            .font(.system(size: 13, weight: .medium))
                        Text("贴图边缘的光晕或投影样式")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $settingsManager.settings.pinShadowStyle) {
                        ForEach(PinShadowStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .frame(width: 190)
                }

                Divider()

                Toggle("截图与贴图时播放快门音效", isOn: $settingsManager.settings.playSoundEffects)
                Toggle("鼠标下方显示放大镜与取色器", isOn: $settingsManager.settings.showMagnifierLoupe)
                Toggle("选好区域后立即自动复制到剪贴板", isOn: $settingsManager.settings.autoCopyToClipboardOnCapture)
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
    }

    // MARK: - 输出
    private var outputTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("输出与存储")
                .font(.headline)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("默认格式：")
                    Spacer()
                    Picker("", selection: $settingsManager.settings.imageFormat) {
                        ForEach(ImageOutputFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .frame(width: 120)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("保存目录：")
                    HStack {
                        Text(settingsManager.settings.saveDirectoryPath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(6)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)

                        Button("选择文件夹…") {
                            chooseDirectory()
                        }
                    }
                }
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
    }

    private func chooseDirectory() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                settingsManager.settings.saveDirectoryPath = url.path
            }
        }
    }

    // MARK: - 翻译
    @State private var translationTestResult: String = ""

    private var translationTab: some View {
        let cfg = $settingsManager.settings.translation
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("翻译（LLM API）")
                    .font(.headline)

                HStack {
                    Toggle("在工具栏显示翻译按钮", isOn: cfg.enabled)
                    if cfg.enabled.wrappedValue && cfg.apiKey.wrappedValue.isEmpty {
                        Text("⚠️ API Key 未填写").font(.system(size: 11)).foregroundColor(.orange)
                    }
                }

                Divider()

                Text("BaseURL（OpenAI 兼容）").font(.subheadline).foregroundColor(.secondary)
                TextField("https://open.bigmodel.cn/api/paas/v4", text: cfg.baseURL)
                    .textFieldStyle(.roundedBorder)

                Text("模型名称").font(.subheadline).foregroundColor(.secondary)
                TextField("glm-4-flash-250414", text: cfg.modelName)
                    .textFieldStyle(.roundedBorder)
                Text("速度提示：智谱的 `glm-4-flash` 是浮动别名，实测比带日期的快照版（glm-4-flash-250414）慢 2~3 倍；`glm-4-air` 更快但按量计费。换模型只改这里即可。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("API Key").font(.subheadline).foregroundColor(.secondary)
                SecureField("sk-…", text: cfg.apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("目标语言").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    TextField("简体中文 / English / 日本語 / …", text: cfg.targetLanguage)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }

                Toggle("直接传图给视觉模型（跳过 OCR）", isOn: cfg.isVisionModel)
                    .help("仅当模型支持图片输入时启用，例如 glm-4v-flash / gpt-4o")

                Text("系统提示词").font(.subheadline).foregroundColor(.secondary)
                TextEditor(text: cfg.systemPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("提示：使用 {{TARGET}} 表示目标语言占位符。")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                HStack {
                    Button("测试连接") {
                        let c = settingsManager.settings.translation
                        Task { @MainActor in
                            do {
                                let svc = TranslationService()
                                let msg = try await svc.testConnection(config: c)
                                translationTestResult = msg
                            } catch {
                                translationTestResult = "❌ \(error.localizedDescription)"
                            }
                        }
                    }
                    if !translationTestResult.isEmpty {
                        Text(translationTestResult)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let win = NSWindow(contentViewController: hosting)
            win.title = "SnipShot 偏好设置"
            win.styleMask = [.titled, .closable]
            win.center()
            win.isReleasedWhenClosed = false
            self.window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

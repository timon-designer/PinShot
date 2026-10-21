import Cocoa
import SwiftUI
import PinShotCore

@MainActor
public protocol FloatingToolbarDelegate: AnyObject {
    func toolbarDidSelectPin()
    func toolbarDidSelectAnnotate()
    func toolbarDidSelectCopy()
    func toolbarDidSelectSave()
    func toolbarDidSelectTranslate()
    func toolbarDidSelectClose()
    func toolbarDidChangeTool(_ tool: AnnotationToolType)
    func toolbarDidChangeColor(_ color: ColorRepresentation)
    func toolbarDidChangeStrokeWidth(_ width: CGFloat)
    func toolbarDidUndo()
    func toolbarDidRedo()
}

/// 悬浮工具条的**唯一状态真源**。
///
/// 之前这些值都放在 `FloatingToolbarView` 的 `@State` 里，于是每次
/// `showToolbar(near:)` 都得重建整个 `NSHostingView` 才能把新状态灌进去 ——
/// 而拖动选区时 `mouseDragged` 每帧都会调一次，等于一秒钟换几十个 contentView。
/// 在 AppKit 的显示周期里不停替换带 AutoLayout 约束的 contentView，
/// 就是 2026-10-14 / 2026-10-20 两次「约束更新事务里抛 NSException」闪退的来源。
///
/// 现在视图只创建一次，状态变化走 `ObservableObject` 发布，
/// 彻底消除了「每帧重建 NSHostingView」这条高危路径。
@MainActor
final class FloatingToolbarModel: ObservableObject {
    @Published var isAnnotating: Bool = false
    @Published var selectedTool: AnnotationToolType = .rectangle
    @Published var selectedColor: ColorRepresentation = .red
    @Published var strokeWidth: CGFloat = 3.0
    @Published var translationAvailable: Bool = false
}

@MainActor
struct FloatingToolbarView: View {
    weak var delegate: FloatingToolbarDelegate?
    @ObservedObject var model: FloatingToolbarModel

    var body: some View {
        VStack(spacing: 8) {
            // Main Action Bar
            HStack(spacing: 6) {
                // 贴图按钮
                ToolbarButton(
                    icon: "pin.fill",
                    title: "贴图 (P)",
                    tint: .orange
                ) {
                    delegate?.toolbarDidSelectPin()
                }

                // 标注切换按钮
                ToolbarButton(
                    icon: model.isAnnotating ? "pencil.circle.fill" : "pencil.circle",
                    title: "标注 (A)",
                    tint: model.isAnnotating ? .blue : .primary
                ) {
                    model.isAnnotating.toggle()
                    delegate?.toolbarDidSelectAnnotate()
                }

                Divider()
                    .frame(height: 18)

                // 复制按钮
                ToolbarButton(
                    icon: "doc.on.doc.fill",
                    title: "复制 (⌘C)",
                    tint: .green
                ) {
                    delegate?.toolbarDidSelectCopy()
                }

                // 保存按钮
                ToolbarButton(
                    icon: "arrow.down.circle.fill",
                    title: "保存 (⌘S)",
                    tint: .blue
                ) {
                    delegate?.toolbarDidSelectSave()
                }

                // 翻译按钮（仅在配置完成后出现）
                if model.translationAvailable {
                    ToolbarButton(
                        icon: "character.bubble.fill",
                        title: "翻译 (T)",
                        tint: .purple
                    ) {
                        delegate?.toolbarDidSelectTranslate()
                    }
                }

                Divider()
                    .frame(height: 18)

                // 取消按钮
                ToolbarButton(
                    icon: "xmark.circle.fill",
                    title: "取消 (Esc)",
                    tint: .red
                ) {
                    delegate?.toolbarDidSelectClose()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Extended Annotation Sub-Toolbar (Conditional)
            if model.isAnnotating {
                Divider()

                VStack(spacing: 8) {
                    // Tool Selection
                    HStack(spacing: 8) {
                        ToolOptionButton(icon: "rectangle", isSelected: model.selectedTool == .rectangle) {
                            select(.rectangle)
                        }
                        ToolOptionButton(icon: "oval", isSelected: model.selectedTool == .ellipse) {
                            select(.ellipse)
                        }
                        ToolOptionButton(icon: "arrow.up.right", isSelected: model.selectedTool == .arrow) {
                            select(.arrow)
                        }
                        ToolOptionButton(icon: "pencil.tip", isSelected: model.selectedTool == .pen) {
                            select(.pen)
                        }
                        ToolOptionButton(icon: "highlighter", isSelected: model.selectedTool == .highlighter) {
                            select(.highlighter)
                        }
                        ToolOptionButton(icon: "textformat", isSelected: model.selectedTool == .text) {
                            select(.text)
                        }
                        ToolOptionButton(icon: "1.circle.fill", isSelected: model.selectedTool == .step) {
                            select(.step)
                        }
                        ToolOptionButton(icon: "squareshape.split.3x3", isSelected: model.selectedTool == .mosaic) {
                            select(.mosaic)
                        }

                        Spacer()

                        // Undo / Redo
                        Button(action: { delegate?.toolbarDidUndo() }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)

                        Button(action: { delegate?.toolbarDidRedo() }) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)

                    // Color Swatches & Stroke Width
                    HStack(spacing: 8) {
                        ForEach(ColorRepresentation.defaultPresets, id: \.hexString) { preset in
                            Circle()
                                .fill(Color(red: preset.red, green: preset.green, blue: preset.blue))
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: model.selectedColor == preset ? 2 : 0)
                                )
                                .shadow(radius: 1)
                                .onTapGesture {
                                    model.selectedColor = preset
                                    delegate?.toolbarDidChangeColor(preset)
                                }
                        }

                        Spacer()

                        // Stroke size picker
                        Picker("", selection: $model.strokeWidth) {
                            Text("S").tag(CGFloat(2.0))
                            Text("M").tag(CGFloat(4.0))
                            Text("L").tag(CGFloat(7.0))
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 80)
                        .onChange(of: model.strokeWidth) { _, newWidth in
                            delegate?.toolbarDidChangeStrokeWidth(newWidth)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.8)
        )
        .frame(minWidth: 320)
    }

    private func select(_ tool: AnnotationToolType) {
        model.selectedTool = tool
        delegate?.toolbarDidChangeTool(tool)
    }
}

private struct ToolbarButton: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

private struct ToolOptionButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .blue : .secondary)
                .frame(width: 24, height: 24)
                .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

/// 悬浮工具条窗口。
///
/// 三个关键修正（都在修同一类崩溃/串扰）：
/// 1. **不再抢 key window**：工具条只用鼠标点，永远不需要键盘焦点。
///    以前每次显示都调 `makeKeyAndOrderFront`，但 borderless panel 的
///    `canBecomeKeyWindow` 是 NO，系统于是反复打日志
///    「[NSWindow makeKeyWindow] called on <PinShot.FloatingToolbarPanel> which returned NO」，
///    同时还把 key 从截图遮罩手里抢走（表现为截图时按 T / Esc 失灵）。
///    现在显式 `canBecomeKey = false` + `orderFrontRegardless()`。
/// 2. **不再是 0 尺寸起手**：以前 `contentRect: .zero` 然后再塞一个
///    `NSHostingView` 进去，窗口在 0×0 状态下的约束解算是异常高发区。
/// 3. **contentView 只设一次**（由 OverlayWindowManager 保证），
///    不再每帧换 hostingView，约束系统不再反复重建。
final class FloatingToolbarPanel: NSPanel {
    /// 工具条不接收键盘输入，明确拒绝成为 key window（见上面第 1 点）。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver + 1
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 刻意不开 isFloatingPanel：它会把 level 重置成 .floating(3)，
        // 掉到截图遮罩(1000) 下面，也会在应用失活时自动隐藏。
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.hasShadow = true

        // 用 autoresizing 让 hostingView 贴着窗口走，
        // 避免「窗口 frame」和「view 约束」两套规则互相拉扯。
        contentView.autoresizingMask = [.width, .height]
        contentView.frame = self.contentRect(forFrameRect: frame)
        self.contentView = contentView
    }
}

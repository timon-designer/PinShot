import SwiftUI
import AppKit

struct PermissionOnboardingView: View {
    @ObservedObject var permissionService = PermissionService.shared
    var onPermissionGranted: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // App Icon / Header
            // 直接用 bundle 里的真实应用图标；取不到时（例如 swift run 调试）
            // 退回代码绘制的圆，界面不至于空一块。
            Group {
                if let icon = AppIconProvider.image {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 88, height: 88)
                        .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 5)
                } else {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)

                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.top, 8)

            // 头部标题
            VStack(spacing: 6) {
                Text("屏幕录制权限")
                    .font(.system(size: 19, weight: .bold))

                Text("SnipShot 需要屏幕录制权限，才能截取多显示器画面并制作浮动贴图。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 380)
            }

            // 操作步骤
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "1.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 15))
                    Text("点下方「打开屏幕录制设置」，跳到「隐私与安全性 → 录屏与系统录音」。")
                        .font(.system(size: 12))
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "2.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 15))
                    Text("点列表下方的 **＋** 号，在「应用程序」里选中 **SnipShot.app**，再点「打开」。")
                        .font(.system(size: 12))
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "3.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 15))
                    Text("添加成功后开关会**自动打开**，本窗口会自动关闭。")
                        .font(.system(size: 12))
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 15))
                    Text("macOS 26 不会为自签名 App 自动弹授权提示，列表里也不会自动出现。**必须手动点 ＋ 添加**，这是唯一的授权方式。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )

            // Action Buttons
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button(action: {
                        permissionService.openSystemSettings()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.fill")
                            Text("打开系统设置")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: {
                        permissionService.requestPermission()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.raised.fill")
                            Text("请求权限")
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                HStack(spacing: 12) {
                    Button(action: {
                        let appUrl = Bundle.main.bundleURL
                        NSWorkspace.shared.activateFileViewerSelecting([appUrl])
                    }) {
                        Label("在访达中显示 SnipShot.app", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.link)

                    Spacer()

                    Button(action: {
                        if permissionService.checkPermission() {
                            onPermissionGranted()
                        } else {
                            permissionService.requestPermission()
                        }
                    }) {
                        Text("重新检查")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
                .padding(.horizontal, 4)

                Divider()
                    .padding(.horizontal, 4)

                // macOS 对屏幕录制权限有系统级限制：开关已打开但当前进程未必生效，
                // 重启 App 是最可靠的解法，所以这里给一个显式入口。
                VStack(spacing: 6) {
                    Text("勾选后仍提示未授权？")
                        .font(.system(size: 11, weight: .medium))

                    Text("这是 macOS 对屏幕录制权限的系统级限制，不是配置错误。点下面的按钮重启一次即可生效。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 340)

                    Button(action: {
                        permissionService.relaunchApp()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("重启 SnipShot")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: 380)
            .padding(.bottom, 6)
        }
        .padding(24)
        .frame(width: 440)
        .onReceive(permissionService.$hasScreenRecordingPermission) { granted in
            if granted {
                onPermissionGranted()
            }
        }
    }
}

@MainActor
final class PermissionWindowManager {
    static let shared = PermissionWindowManager()
    private var window: NSWindow?

    func show(onGranted: @escaping () -> Void) {
        if window == nil {
            let view = PermissionOnboardingView(onPermissionGranted: { [weak self] in
                self?.close()
                onGranted()
            })
            let hostingController = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hostingController)
            win.title = "SnipShot 权限"
            win.styleMask = [.titled, .closable]
            win.titlebarAppearsTransparent = true
            win.center()
            win.isReleasedWhenClosed = false
            self.window = win
        }
        // 关键修复：窗口一显示就开始轮询。
        // 否则用户跳到系统设置勾选开关后，App 永远感知不到，界面会一直停在"未授权"。
        // 双保险：轮询本身也带 onGranted 回调，即使 SwiftUI 视图被销毁也能收到通知。
        PermissionService.shared.startPolling {
            SnipLog.write("权限窗口: 轮询确认授权 → 关闭窗口并继续")
            PermissionWindowManager.shared.close()
            onGranted()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

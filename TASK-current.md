# TASK：修复 PinShot 截图 App 闪退

## 背景
- 仓库：`~/WorkBuddy/软件制作/SnipShotBase`（Swift/SwiftUI/AppKit，产物 PinShot.app，安装在 /Applications/SnipShot.app，Info 版本 0.2）
- 涛哥反馈近两周闪退几次。已核实两份系统崩溃日志（~/Library/Logs/DiagnosticReports/Retired/PinShot-2026-10-14-*.ips 和 PinShot-2026-10-20-*.ips），两次崩溃栈完全一致：
  - EXC_BREAKPOINT (SIGTRAP)，AppKit `+[NSApplication _crashOnException:]`
  - 栈：CA::Transaction::flush → NSWindow updateConstraintsIfNeeded → NSView updateConstraintsForSubtreeIfNeeded → ___NSViewUpdateConstraints_block_invoke → _crashOnException
  - 即：约束更新期间抛出未捕获的 NSException（AutoLayout 约束冲突被 AppKit 以异常形式抛出），导致整 app 闪退。

## 复现线索
- 崩溃前后日志里大量重复错误：`[NSWindow makeKeyWindow] called on <PinShot.FloatingToolbarPanel> which returned NO from -[NSWindow canBecomeKeyWindow]`（悬浮工具条窗口被反复调 makeKeyWindow）。重点排查 `Sources/PinShot/FloatingToolbarView.swift` 和 `OverlayWindowManager.swift`：
  1. FloatingToolbarPanel 的 canBecomeKeyWindow / 布局约束在面板隐藏/复用时是否失效或自相矛盾；
  2. 截图流程中约束更新事务里（layoutSubviews/updateConstraints/动画块内）是否直接改 window/约束导致异常；
  3. 防御性兜底：用 NSSetUncaughtExceptionHandler + DispatchQueue.main.async 包住约束更新路径，至少做到抛异常时不闪退、重建面板。

## 验收标准
1. 修复约束崩溃根因（或加防护使同类异常不再杀进程）；
2. 本机 `swift build -c release && ./scripts/<打包脚本>` 构建通过；
3. 新版本号 ≥ 0.3（Info.plist CFBundleShortVersionString）；
4. 交付：/Applications/SnipShot.app 已被新版本替换，涛哥正常使用一次截图无异常。

## 发布清理（新增，涛哥要求）
- 打包脚本发布新版到 /Applications 后，自动删除项目内 build/ 下的 .app 副本和 ~/Library/Developer/Xcode/DerivedData/SnipShotBase-* 缓存，防止老版本残留在本地被误触。
- 同样规则适用于 BalanceBar（余额看板）项目，脚本一并加。

## 完成后
- 更新本仓库 git 提交（涛哥会自己 review 界面）。

# SnipShot 改造方案 & 完成记录

基线：[Greek-Cp/PinShot](https://github.com/Greek-Cp/PinShot) v1.0
定位：Snipaste 风格原生 macOS 截图 + 贴图 + 翻译
完成日期：2026-09-10
目标环境：macOS 14+，Apple Silicon / Intel 均支持

---

## 2026-10-08 新增：应用图标（AppIcon.icns）

> 在此之前项目里**完全没有图标**：`Contents/Resources` 是空的，`Info.plist` 里没有
> `CFBundleIconFile`，访达里显示的是通用占位图标。

### 尺寸规范（实测，不是照抄记忆）

从本机三个真实 App 的 `.icns` 里把数值量出来：

| 项 | 值 | 来源 |
|---|---|---|
| 画布 | 1024 × 1024 透明 | 三个样本一致 |
| 主体 squircle | 824 × 824，居中 → 四边留白 100px | Tabbit / 腾讯会议 alpha>250 实测 |
| 圆角半径 | 185.4（= 824 × 0.225） | 逐深度测左侧内缩量后拟合 |
| 投影 | 烘焙进图，外扩约 L72/T85/R72/B61 | 参考图 alpha>0 包围盒 |

轮廓模型验证：把参考图标在深度 d = 2/4/8/16/32/64/96/128 处的左侧内缩量逐点量出来，
与「圆角矩形 r=185.4」在中段完全吻合；且**顶边中点与主体顶边齐平**，说明不是超椭圆
（超椭圆会有鼓包）→ **用圆角矩形，不用超椭圆**。

### 图标构成

- 石墨渐变 squircle 底（顶部受光 + 极淡内描边高光）
- 白色四角取景框 —— 与 `MenuBarController.makeIcon()` 的代码绘制图标同一套视觉语言
- 中心蓝紫渐变方块 —— 「被截下 / 被钉住的那一块」，色取自 App 自身权限引导页的
  `Color.blue → Color.purple`

小尺寸（≤32px）自动切「加粗版」：框线更粗、方块更大、去掉辉光。1024 下 46px 的框线
缩到 16px 只剩 0.6px，会糊成一团 —— Apple 自家图标也是在小尺寸换简化稿。

### 生成方式

```bash
python3 scripts/make-icon.py --preview
# 产出 Resources/AppIcon.iconset/（10 张源图）+ Resources/AppIcon.icns + 预览图
```

纯 PIL 绘制，超采样 4× 后 LANCZOS 降采样。改配色/比例只改脚本顶部的常量，重跑即可。

### 接入点（**三处，缺一不可**）

macOS 只在 **bundle 内部**找 `.icns`，不会去源码目录看 —— 这是最容易静默失败的地方：
plist 写了图标名但没把 `.icns` 拷进去，不报错，只是图标不显示。

| # | 位置 | 作用 |
|---|---|---|
| 1 | `Resources/AppIcon.icns` | 图标源文件（唯一真源） |
| 2 | `run-local.sh` → 拷到 `Contents/Resources/AppIcon.icns` + plist 写 `CFBundleIconFile` | 访达 / 启动台 / 系统设置的「屏幕录制」列表 |
| 3 | `Sources/PinShot/AppIconProvider.swift` | App **自己**的界面（权限引导页头部、关于面板） |

> 只写 `CFBundleIconFile` 而**不设** `CFBundleIconName`：后者指向资源目录
> `Assets.car` 里的图标名，我们没有资源目录，设了反而会让系统找不到图标退回通用图。

运行时：`AppDelegate` 把 `AppIconProvider.image` 赋给 `NSApp.applicationIconImage`
（关于面板读的是这个属性，不是 bundle 图标），启动日志会打
`应用图标: 已加载 {512, 512}` —— 这条日志就是图标接好没接好的自检点。

顺带补了一个 **「关于 SnipShot」** 菜单项（`MenuBarController`）：标准关于面板是 macOS
上放大展示应用图标的标准位置，而这个 App 之前没有任何地方能看到自己的图标。

### 验收

- `run-local.sh` 末尾新增图标自校验：`CFBundleIconFile` 指的名字 + `Contents/Resources`
  里真有这个文件，缺一个就报错退出（和已有的 CDHash 自校验同一个思路）
- `NSWorkspace.icon(forFile:)` 实测解析到 **2048px** 位图 → 图标已被 Launch Services 正确接管
- 访达截图确认：与 Snipaste / Tabbit / Siri 并排，squircle 形状、尺寸、投影一致
- 应用日志确认 `应用图标: 已加载 {512, 512}`；关于面板截图确认图标正常显示
- `bash scripts/verify-pin.sh` → **16/16 通过**，图标改动未影响贴图交互

---

## 2026-10-08 修复：贴图不能拖动 / 不能缩放

> 现象：贴图窗正常出现，但①按住完全拖不动；②滚轮/捏合无反应。
> 排查手段：写了两个无头工具 —— `pinstate`（CGEvent 合成鼠标键盘 + CGWindowList 量窗口
> 几何）、`draglab`（三个同规格窗口做 A/B 对照）。全部结论都是**实测**出来的，不是猜的。

### 根因（4 个，都是独立的）

| # | 根因 | 证据 | 修法 |
|---|---|---|---|
| 1 | `isMovableByWindowBackground` 对这个窗口**根本无效** | draglab 三窗对照：W1（原样）/W2（覆写 `mouseDownCanMoveWindow=true`）都收到全部 21 个 `mouseDown/mouseDragged`，**窗口坐标一动不动**；W3（纯 NSView 手动 `mouseDragged`）精确跟随 +70,+70 | 在 `PinHostingView` 手写 `mouseDown/mouseDragged/mouseUp` 搬窗口；并把 `isMovableByWindowBackground` 显式设为 `false`（避免某版本 AppKit 生效时双倍位移） |
| 2 | 非前台时**第一次点击被系统吞掉** | 应用失活后点击贴图，`mouseDown` 日志**一行都没有** | `override func acceptsFirstMouse(for:) -> Bool { true }` |
| 3 | 最外圈 16px 光晕留白**收不到任何事件** | 内缩 2/6/12/15px 处 `mouseDown` 不到达视图，内缩 19px 才生效。该圈是全透明像素，macOS 把点击**透传给了下面的窗口** | `PinContentView` 最外层加 `.background(Color.black.opacity(0.005))`（1/255，肉眼不可见）+ `.contentShape(Rectangle())`；`PinHostingView` 再补一个 `hitTest` 兜底 |
| 4 | borderless 窗口有一条**隐形边缘 resize 带** | 实测：距窗口边缘 2~10px 按下被 AppKit 当成拉角缩放（492×352 → 450×322），≥12px 才是拖动。那条带正好落在看不见的光晕圈里 → 「按着边想拖」会莫名把贴图缩小 | `styleMask` **去掉 `.resizable`**。缩放已有滚轮/捏合/双指双击复位三条路径，不需要这条隐藏拖拽，于是**整个窗口矩形都成了拖动面** |

### 滚轮缩放的另外两个坑

- **方向随系统设置翻转**：原实现 `rawDelta = -scrollingDeltaY`，实测滚轮向上反而是**缩小**。
  改为按 `isDirectionInvertedFromDevice` 归一化到「物理方向」，滚轮/双指远离自己 = 放大。
- **⇧ 粗调完全失效**：按住 ⇧ 滚轮时 macOS 会把垂直滚动**转成横向滚动**，
  实测拿到的是 `scrollingDeltaY=0 / scrollingDeltaX=+3`，只看 Y 自然一点反应都没有。
  改为取「主导轴」`abs(dy) >= abs(dx) ? dy : dx`。
- 触控板给的是像素级小数（`hasPreciseScrollingDeltas`），额外乘 0.15 衰减，否则一划就飞。

### 捏合

`magnify(with:)`（responder 链，逐事件增量）为主路径，`NSMagnificationGestureRecognizer`
保留为兜底，但一旦收到 responder 链的 magnify 就自动停用 —— 避免同一次捏合被两条路径
重复应用（会「一跳一跳」）。两条路径共用同一套以鼠标为锚点的缩放数学。

### 验收（`accept.sh`，16/16 通过）

```
验收① 按住任意位置都能拖动 —— 留白圈·左上/顶边中段/左中段、圆角附近、图片左上/正中/右下  ✅ 7/7
验收② 滚轮 向上=放大 / 向下=缩小 / 以鼠标为锚点不跳位 / ⌥细调(Δ69) / ⇧粗调(Δ1404)      ✅ 5/5
验收①-b 应用失活（贴图浮在别的 App 上）拖动 + 滚轮                                        ✅ 2/2
回归  双击关闭仍生效 / 右键只弹菜单不误拖动                                                ✅ 2/2
```

实时日志实证：
```
Pin: mouseDown 起锚 mouse={630,562} win={384,386}
Pin: 拖动结束 origin={474,326} size={492,352}                      ← Δ=(+90,-60) 精确
Pin: 滚轮 dx=0.00 dy=3.00 mods=0       → factor=1.120             ← 普通档 1+3×0.04
Pin: 滚轮 dx=0.00 dy=3.00 mods=524288  → factor=1.030             ← ⌥ 细调 1+3×0.01
Pin: 滚轮 dx=3.00 dy=0.00 mods=131072  → factor=1.300             ← ⇧ 被转成横向，1+3×0.10
```

### 顺带修掉的构建脚本 bug

`run-local.sh` 里 `$NEW_AUTH）` / `$XCB_LOG）` 变量后面直接跟**全角右括号**，bash 会把
`NEW_AUTH）` 整个当成变量名 → `set -u` 下报 unbound variable → **脚本在「安装到 /Applications」
之前就静默中止**，表现是「编译成功但装的还是旧版本」。改成 `${NEW_AUTH}`。

### 使用 `run-local.sh` 的注意事项

- 本机 `xcode-select` 指向 CommandLineTools，`xcodebuild` 会失败（记 ResultBundle 后退出），
  脚本会自动回退到 `swift build --disable-sandbox`（~6s，正常）。
- **验收套件已固化进项目**：`bash scripts/verify-pin.sh`（首次会自动编译 `scripts/pinstate.swift`）。
  它用合成事件 + 量窗口几何跑完上面 16 项检查，改完任何贴图相关代码都该跑一遍。
  应用侧实时日志在 `/tmp/snipshot.log`，`grep 'Pin:'` 能看到每次拖动起锚/结束、每次滚轮的
  `dx/dy/mods/factor`。
- ⚠️ **写 shell 脚本时 `$VAR` 后面绝不能紧跟中文/全角符号/箭头**：bash 在 UTF-8 locale 下
  会把那些高字节当成合法标识符字符，于是 `$R1→` 被解析成变量名 `R1→`，
  `set -u` 下直接 `unbound variable` 中止脚本。一律写 `${R1}`。
  本次 `run-local.sh`（`$NEW_AUTH）`/`$XCB_LOG）`）和 `scripts/verify-pin.sh` 都栽过这个坑。
- ⚠️ 合成 ⌘⇧A 之后**必须补发一个空 flags 的 `flagsChanged`**，否则系统一直认为 ⌘⇧ 按着，
  后续滚轮会被转成横向、`modifierFlags` 全被污染，验收结果全是假象。

## ✅ 全部 4 项改造已完成

### ① 滚轮调粗细 — DONE

**位置**：`Sources/PinShot/OverlayCanvasView.swift`（新增 `scrollWheel(with:)` 覆写）
**协作**：`Sources/PinShot/OverlayWindowManager.swift`（新增 `adjustActiveStrokeWidth(by:minWidth:maxWidth:)`）

行为：
- 进入标注模式 → 在 Overlay 上滚动 → 当前工具的 strokeWidth 改变（默认步长 1.0）
- Option + 滚轮 = 0.5 步（细调）
- Shift + 滚轮 = 4.0 步（粗调）
- 非标注模式 → 缩放选区（以鼠标为锚点）
- Picker 自动同步显示当前粗细（每次都重建 toolbar）

### ② 贴图拖动 + 滚轮缩放 — DONE（2026-10-08 重修，根因见本文档开头）

**位置**：`Sources/PinShot/PinWindow.swift`

行为：
- **按住窗口内任意位置拖动**（含最外圈 16px 光晕留白）→ 手动搬窗口；
  `mouseDown` 后照常 `super`，所以 hover 按钮 / 右键菜单 / 双击关闭完全不受影响
- 鼠标在 PinWindow 内滚动 → 按比例缩放（默认步长 0.04）
- Option = 0.01 步（细调）
- Shift = 0.10 步（粗调）—— 注意 macOS 会把 ⇧+滚轮**转成横向滚动**，代码取主导轴处理
- 以**鼠标全局坐标**为锚点（不会跳位）
- 滚轮 / 双指捏合共用同一套锚点缩放数学；捏合以 responder 链 `magnify(with:)` 为主，
  `NSMagnificationGestureRecognizer` 仅作兜底且收到 magnify 后自动让位（避免重复应用）
- 双指双击（`smartMagnify`）→ 尺寸复位到 100%

### ③ 截图框边角 resize — 已有（PinShot 自带）

**位置**：`Sources/PinShotCore/Geometry.swift` `SelectionRect.hitHandle` + `resized`
**绘制**：`Sources/PinShot/OverlayCanvasView.swift` `drawHandles`

行为：拉出选区后 8 个 8×8 把手自动出现（4 角 + 4 边），鼠标经过自动换 cursor：
- 角 → `crosshair`
- 左右边 → `resizeLeftRight`
- 上下边 → `resizeUpDown`
- 内部 → `openHand`

### ④ OCR + 通用 OpenAI 兼容翻译 — DONE

**新文件**：
- `Sources/PinShotCore/OCRService.swift`（Apple Vision 异步 OCR）
- `Sources/PinShotCore/TranslationService.swift`（OpenAI-兼容 HTTP client）
- `Sources/PinShot/TranslationFlow.swift`（协调器 + 结果浮窗）
- `Settings.swift` 新增 `TranslationConfig` 模型

**触发方式**：
- 工具栏新增 「Translate (T)」 按钮（紫色，仅在 Settings 配好后显示）
- 工具栏内键盘 T
- 流程：Vision OCR → POST `/chat/completions` → 浮窗展示「原文 / 译文」双栏
- 也支持「直接传图给视觉模型」（如 `glm-4v-flash`、`gpt-4o`），跳过 OCR

**配置入口（Settings → Translation）**：
- BaseURL（默认 `https://open.bigmodel.cn/api/paas/v4`）
- Model Name（默认 `glm-4-flash`）
- API Key（SecureField，存入 UserDefaults）
- 目标语言（默认 `简体中文`）
- System Prompt（`{{TARGET}}` 占位）
- 「直接传图」开关
- 一键「测试连接」按钮

**结果浮窗**：
- 自动出现在屏幕右上角
- 原文/译文切换 Tab
- 「复制」「复制并关闭」按钮
- 可拖动、可关闭

## 构建

```bash
cd /Users/taoliu/WorkBuddy/软件制作/SnipShotBase
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme PinShot -destination 'platform=macOS' build
```

或者在 `xed SnipShotBase` 打开 Xcode 后直接 Build & Run。

注意：纯 `swift build` 在 CommandLineTools SDK 27 下有 `SwiftUI.State` macro 解析 bug，
必须用 Xcode 26 工具链。

## 安装到 /Applications

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/SnipShotBase-*/Build/Products/Debug/PinShot.app /Applications/
```

首次启动需授权：
- 「屏幕录制」必需（截图）
- 「辅助功能」非必需（除非要改全局热键）
- 网络出站（仅触发翻译时才用）

## 文件清单

```
SnipShotBase/
├── Package.swift                 # SPM (依赖数量: 0)
├── Sources/
│   ├── PinShotCore/              # 共享逻辑
│   │   ├── Geometry.swift        # SelectionRect + 8 handle hit-test（已有）
│   │   ├── AnnotationModel.swift # 标注数据
│   │   ├── AnnotationRenderer.swift
│   │   ├── ColorUtils.swift
│   │   ├── HistoryStack.swift
│   │   ├── Settings.swift        # ⭐ 新增 TranslationConfig
│   │   ├── OCRService.swift      # ⭐ 新增
│   │   └── TranslationService.swift # ⭐ 新增
│   └── PinShot/                  # AppKit + SwiftUI App
│       ├── PinShotApp.swift
│       ├── AppDelegate.swift
│       ├── AppIconProvider.swift  # ⭐ 新增: 应用图标统一入口（bundle .icns → NSApp）
│       ├── MenuBarController.swift
│       ├── PermissionService.swift
│       ├── PermissionOnboardingView.swift
│       ├── HotKeyService.swift
│       ├── CaptureService.swift
│       ├── OverlayWindowManager.swift  # ⭐ 改: 滚轮 + 翻译委托
│       ├── OverlayCanvasView.swift     # ⭐ 改: scrollWheel
│       ├── PinWindow.swift             # ⭐ 改: cursor-anchored scrollWheel zoom
│       ├── PinHostingView/...          # 已有 2 指捏合
│       ├── FloatingToolbarView.swift   # ⭐ 改: Translate 按钮
│       ├── LoupeView.swift
│       ├── TranslationFlow.swift  # ⭐ 新增
│       ├── SettingsManager.swift
│       ├── SettingsView.swift     # ⭐ 改: Translation 标签
│       ├── PasteboardService.swift
│       ├── SoundService.swift
│       └── PinAuraGlowView.swift
├── Resources/
│   ├── Info.plist                # ⭐ 改: 新增 CFBundleIconFile=AppIcon
│   ├── Entitlements.plist
│   ├── AppIcon.icns              # ⭐ 新增: 应用图标（唯一真源，构建时装进 bundle）
│   ├── AppIcon.iconset/          # ⭐ 新增: 10 张尺寸源图（iconutil 可重打包）
│   └── AppIcon-preview.png       # ⭐ 新增: 各尺寸预览（1:1 + 放大 6×）
├── scripts/
│   ├── build-app.sh              # ⭐ 改: 拷图标进 bundle
│   ├── make-icon.py              # ⭐ 新增: 图标生成器（PIL，改常量重跑即可）
│   ├── verify-pin.sh             # 贴图交互无头验收套件
│   └── pinstate.swift            # 验收套件的事件合成工具源码
└── Tests/PinShotCoreTests/
```

## 已知坑

1. **纯 `swift build` 失败**：CommandLineTools SDK 27 下 SwiftUIMacros.StateMacro 解析失败 → 必须用 Xcode 工具链。
2. **TCC 录屏绑定 cdhash**：每次 rebuild 后录屏授权会丢失 → Xcode build & Run 时记得让系统设置开关「关再开」。
3. **macOS 26 隐藏菜单栏项目机制**：与 SnipTranslateMac 同源问题 —— 已用 `com.taoliu.snipshot` 干净 id 起步。
4. **翻译浮窗是 always-on-top**：可被任何其他 always-on-top 窗口遮挡，但不会被普通窗口遮挡。

# PinShot 📌

**截图 · 贴图 · 标注 · AI 翻译**，一款 100% 原生的 macOS 截图工具（AppKit + SwiftUI + ScreenCaptureKit，Swift 6），遵循 Apple HIG，轻量、无 Electron。

**Languages:** 简体中文 · [English](README.en.md)

---

## 🙏 来源与致谢

本仓库 Fork 自开源项目 [Greek-Cp/PinShot](https://github.com/Greek-Cp/PinShot)（开源、离线优先的 macOS / Windows 截图贴图工具），并已合入上游 macOS 原生版（`feat/native-macos-app`）。

在此基础上，本 Fork 由 [timon-designer](https://github.com/timon-designer) 继续维护，主要新增：

- **🌐 截图 AI 翻译**：截图后一键 OCR + LLM 翻译（详见下文）
- 多项截图 / 贴图体验修复（前台抢占、工具条崩溃等）

> 上游仓库未附带 LICENSE 文件，本项目沿用同样状态，版权归原作者所有。

---

## ✨ 功能

- **🚀 100% 原生 macOS**：无 Web 框架开销，性能拉满
- **🔒 权限引导**：启动时检测屏幕录制权限，交互式引导 + 一键跳转系统设置
- **⚡️ 全局快捷键 `⌘⇧A`**：冻结屏幕，呼出截图遮罩
- **🖥 多屏跨屏框选**：不同分辨率 / Retina DPI 的显示器间连续拖选
- **📌 浮动贴图**：截图钉在桌面（所有空间置顶），可拖动、等比缩放，悬停显关闭按钮，右键菜单支持复制 / 保存 / 透明度
- **✏️ 就地标注**：矩形、椭圆、箭头、直线、自由笔、荧光笔、文字、序号徽章（1-2-3…）、色板，支持撤销 / 重做（`⌘Z` / `⌘⇧Z`）
- **📋 即时复制 / 保存**：`⌘C` 复制到剪贴板（带原生音效），`⌘S` 保存文件
- **🔍 精准放大镜**：像素级缩放，HEX / RGB 取色
- **🍸 原生菜单栏**：后台常驻状态栏，无 Dock 图标
- **🌐 截图 AI 翻译**：见下节 👇

---

## 🌐 截图 AI 翻译

截图 → 按一下，**原文译文分段对照**的翻译面板直接弹出。适合看外文报错、文档、界面截图。

### 使用方式

1. `⌘⇧A` 截图框选区域
2. 悬浮工具栏点击紫色 **「翻译 (T)」** 按钮，或直接按 `T`
3. 翻译面板弹出：左侧原文段落，右侧译文，**流式实时输出**

> 翻译按钮只在「设置 → 翻译」中启用并填写 API Key 后才会出现。

### 工作原理（两种模式）

| 模式 | 流程 | 适用 |
|---|---|---|
| **默认：OCR + 文本翻译** | 先用 **Apple Vision 框架本地 OCR**（离线、免费、不上传图片）识别并分段，再把文字段落送 LLM **流式翻译**；网关不支持流式时自动降级为一次性请求 | 任意文本模型 |
| **视觉模型直传** | 跳过 OCR，截图 PNG 直接发给支持图片输入的模型（如 `glm-4v-flash` / `gpt-4o`） | 模型本身能读图 |

### 配置：自带 AI 密钥（Bring Your Own Key）

翻译走 **OpenAI 兼容接口**，密钥由你自己申请、只存在你本机。打开 **PinShot 设置 → 翻译**：

| 配置项 | 说明 | 默认值 |
|---|---|---|
| 在工具栏显示翻译按钮 | 总开关 | 关 |
| BaseURL | 任意 OpenAI 兼容端点 | `https://open.bigmodel.cn/api/paas/v4` |
| 模型名称 | 见下方选型提示 | `glm-4-flash-250414` |
| API Key | 你自己的密钥（`sk-…`） | 空 |
| 目标语言 | 任意，如 `简体中文` / `English` / `日本語` | 简体中文 |
| 系统提示词 | 可自定义，`{{TARGET}}` 会被替换成目标语言 | 专业翻译提示词 |
| 直接传图给视觉模型 | 跳过 OCR（仅图片模型可用） | 关 |

填完点 **「测试连接」** 即可验证。

**推荐入门（免费）**：到 [智谱 BigModel 开放平台](https://open.bigmodel.cn/) 注册、创建 API Key，全部用默认值即可——`glm-4-flash` 系列有免费额度，默认预设开箱即用。

**兼容端点**：OpenRouter、DeepSeek、Moonshot、Ollama 本地模型、自建网关……只要兼容 `/chat/completions` 都行，改 BaseURL + 模型名即可。

**选型提示**（智谱系实测）：`glm-4-flash` 是浮动别名，比带日期的快照版 `glm-4-flash-250414` 慢 2~3 倍；`glm-4-air` 更快但按量计费。

### 隐私

- OCR 默认完全本地（Apple Vision），图片不离开你的电脑
- 仅在翻译时把**识别出的文字**（或开启视觉模式时的图片）发送到**你自己配置**的 API 端点
- API Key 明文存储在本机 UserDefaults，不上传、不统计

---

## 🛠 构建与运行

**环境要求**：macOS 14 (Sonoma) 及以上 · Xcode 15+ / Swift 6.0+

```bash
# 运行测试
swift test

# 运行应用
swift run PinShot
```

---

## 📂 项目结构

```
PinShot/
├── Sources/
│   ├── PinShotCore/               # 纯逻辑层（可跨平台）
│   │   ├── Geometry.swift         # 选区几何 / 命中检测 / 坐标映射
│   │   ├── ColorUtils.swift       # HEX/RGB 解析与预设色
│   │   ├── HistoryStack.swift     # 撤销 / 重做
│   │   ├── AnnotationModel.swift  # 标注模型
│   │   ├── AnnotationRenderer.swift # CoreGraphics 渲染引擎
│   │   ├── OCRService.swift       # Apple Vision 本地 OCR
│   │   ├── TranslationService.swift # OpenAI 兼容 LLM 客户端（流式）
│   │   └── Settings.swift         # 配置模型（含翻译配置）
│   └── PinShot/                   # macOS App 层
│       ├── PinShotApp.swift       # 入口
│       ├── MenuBarController.swift# 菜单栏
│       ├── PermissionService.swift# 屏幕录制权限
│       ├── HotKeyService.swift    # 全局热键 ⌘⇧A
│       ├── CaptureService.swift   # ScreenCaptureKit 截屏
│       ├── OverlayWindowManager.swift # 多屏遮罩协调
│       ├── OverlayCanvasView.swift# 框选 / 标注画布
│       ├── FloatingToolbarView.swift # 悬浮工具栏（Pin/翻译/复制/保存）
│       ├── TranslationFlow.swift  # 翻译流程编排（OCR→LLM→对照面板）
│       ├── PinWindow.swift        # 置顶贴图窗口
│       ├── LoupeView.swift        # 放大镜取色
│       └── SettingsView.swift     # 设置界面（含翻译配置页）
└── Tests/PinShotCoreTests/        # Swift Testing 测试套件
```

---

## 📜 许可

上游 [Greek-Cp/PinShot](https://github.com/Greek-Cp/PinShot) 未声明开源许可证，本 Fork 沿用同样状态。

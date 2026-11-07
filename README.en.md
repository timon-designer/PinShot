# PinShot 📌

**Screenshot · Pin · Annotate · AI Translate** — a 100% native macOS screenshot tool (AppKit + SwiftUI + ScreenCaptureKit, Swift 6). Follows Apple HIG. No Electron, no web views.

**Languages:** [简体中文](README.md) · English

---

## 🙏 Credits & Origin

This repository is forked from the open-source project [Greek-Cp/PinShot](https://github.com/Greek-Cp/PinShot) (an open, offline-first screenshot & pin tool for macOS / Windows), with the upstream native macOS version (`feat/native-macos-app`) merged in.

This fork is maintained by [timon-designer](https://github.com/timon-designer) and adds:

- **🌐 AI Screenshot Translation** — one-click OCR + LLM translation (see below)
- Various capture / pin fixes (foreground stealing, toolbar crash, etc.)

> The upstream repository ships no LICENSE file; this project follows the same status. All rights belong to the original author.

---

## ✨ Features

- **🚀 100% Native macOS:** Full performance with zero web-framework overhead (no Electron/WebView).
- **🔒 Smart Permission Onboarding:** Screen Recording permission check on launch, with interactive guidance and a direct shortcut to macOS System Settings.
- **⚡️ Global Hotkey (`⌘⇧A`):** Press `Command + Shift + A` to freeze the screen and open the capture overlay instantly.
- **🖥 Multi-Monitor Continuous Selection:** Free-form area selection across monitors with mixed resolutions and Retina DPI.
- **📌 Floating Pin Window:** Pin screenshots as always-on-top references (across all Spaces), draggable, resizable (aspect-ratio locked), close button (✕) on hover, and a quick menu (Copy, Save, Opacity).
- **✏️ Rich In-Place Annotations:** Rectangle, Ellipse, Arrow, Line, Freehand Pen, Highlighter, Text, Step number badges (1-2-3...), color swatches, and Undo/Redo (`⌘Z` / `⌘⇧Z`).
- **📋 Instant Copy & Save:** Copy to clipboard with native sound feedback (`⌘C`) or save to file (`⌘S`).
- **🔍 Precision Loupe:** Pixel-level zoom with HEX / RGB color readout.
- **🍸 Native Menu Bar:** Runs in the background as a menu bar status app, no dock icon.
- **🌐 AI Screenshot Translation:** See below 👇

---

## 🌐 AI Screenshot Translation

Screenshot → one click → a **side-by-side paragraph panel** showing original and translated text, streaming in real time. Great for foreign-language error messages, docs, and UI screenshots.

### How to Use

1. Press `⌘⇧A` and select an area
2. Click the purple **Translate (T)** button on the floating toolbar, or just press `T`
3. The translation panel appears: original paragraphs on the left, translations streaming in on the right

> The translate button only appears after you enable it and fill in an API Key in **Settings → Translation**.

### How It Works (Two Modes)

| Mode | Pipeline | Best for |
|---|---|---|
| **Default: OCR + text translation** | Runs **on-device OCR via Apple's Vision framework** (offline, free, no image upload) to detect and segment text, then streams the segments to an LLM for translation; automatically falls back to a single request if the gateway doesn't support streaming | Any text model |
| **Vision model direct** | Skips OCR and sends the screenshot PNG straight to an image-capable model (e.g. `glm-4v-flash` / `gpt-4o`) | Models that can read images |

### Configuration: Bring Your Own Key

Translation uses an **OpenAI-compatible API** — you provide your own key, which never leaves your machine. Open **PinShot Settings → Translation**:

| Field | Description | Default |
|---|---|---|
| Show translate button in toolbar | Master switch | Off |
| BaseURL | Any OpenAI-compatible endpoint | `https://open.bigmodel.cn/api/paas/v4` |
| Model name | See model tips below | `glm-4-flash-250414` |
| API Key | Your own key (`sk-…`) | Empty |
| Target language | Anything, e.g. `简体中文` / `English` / `日本語` | 简体中文 (Simplified Chinese) |
| System prompt | Customizable; `{{TARGET}}` is replaced with the target language | Professional translator prompt |
| Send image directly to vision model | Skips OCR (image models only) | Off |

Click **Test Connection** to verify your setup.

**Recommended quick start (free):** Sign up at [Zhipu BigModel](https://open.bigmodel.cn/), create an API Key, and keep all defaults — the `glm-4-flash` family has a free tier, so the default preset works out of the box.

**Compatible endpoints:** OpenRouter, DeepSeek, Moonshot, local Ollama, self-hosted gateways... anything speaking `/chat/completions`. Just change the BaseURL and model name.

**Model tip** (measured on Zhipu): `glm-4-flash` is a floating alias that runs 2–3× slower than the pinned snapshot `glm-4-flash-250414`; `glm-4-air` is faster but pay-per-use.

### Privacy

- OCR is fully on-device by default (Apple Vision) — images never leave your Mac
- Only the **recognized text** (or the image, if vision mode is on) is sent to the **API endpoint you configured yourself**
- The API key is stored locally in UserDefaults — never uploaded, never tracked

---

## 🛠 Build & Run

**Requirements:** macOS 14 (Sonoma) or later · Xcode 15+ / Swift 6.0+

```bash
# Run tests
swift test

# Run the app
swift run PinShot
```

---

## 📂 Project Structure

```
PinShot/
├── Sources/
│   ├── PinShotCore/               # Pure logic layer (cross-platform)
│   │   ├── Geometry.swift         # Selection rects, hit-testing, coordinate mapping
│   │   ├── ColorUtils.swift       # HEX/RGB parsing, luminance, presets
│   │   ├── HistoryStack.swift     # Generic undo/redo manager
│   │   ├── AnnotationModel.swift  # Annotation shapes, steps, documents
│   │   ├── AnnotationRenderer.swift # CoreGraphics compositing engine
│   │   ├── OCRService.swift       # On-device OCR (Apple Vision)
│   │   ├── TranslationService.swift # OpenAI-compatible LLM client (streaming)
│   │   └── Settings.swift         # Settings models (incl. translation)
│   └── PinShot/                   # macOS App layer
│       ├── PinShotApp.swift       # Main entry point
│       ├── MenuBarController.swift# Menu bar controller
│       ├── PermissionService.swift# Screen recording permissions
│       ├── HotKeyService.swift    # Global hotkey ⌘⇧A
│       ├── CaptureService.swift   # ScreenCaptureKit capture
│       ├── OverlayWindowManager.swift # Multi-screen overlay coordinator
│       ├── OverlayCanvasView.swift# Drag selection & annotation canvas
│       ├── FloatingToolbarView.swift # Floating toolbar (Pin/Translate/Copy/Save)
│       ├── TranslationFlow.swift  # Translation orchestration (OCR→LLM→panel)
│       ├── PinWindow.swift        # Always-on-top pinned window
│       ├── LoupeView.swift        # Pixel magnifier & color picker
│       └── SettingsView.swift     # Settings UI (incl. translation tab)
└── Tests/PinShotCoreTests/        # Swift Testing suite
```

---

## 📜 License

The upstream project [Greek-Cp/PinShot](https://github.com/Greek-Cp/PinShot) declares no open-source license; this fork follows the same status.

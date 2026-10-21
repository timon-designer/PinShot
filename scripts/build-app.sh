#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

CONFIG="${1:-release}"
echo "🔨 Building PinShot ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH="$ROOT_DIR/.build/$CONFIG/PinShot"
APP_DIR="$ROOT_DIR/PinShot.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "📦 Creating macOS App Bundle at $APP_DIR..."
# Kill existing running process if any
pkill -f "PinShot.app/Contents/MacOS/PinShot" || true

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$BIN_PATH" "$MACOS_DIR/PinShot"
chmod +x "$MACOS_DIR/PinShot"

# Copy Info.plist
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# Copy app icon —— Info.plist 里的 CFBundleIconFile=AppIcon 指的就是它。
# 必须是 .icns 且落在 Contents/Resources/，否则 Finder 显示通用图标。
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  echo "🎨 Icon copied → Contents/Resources/AppIcon.icns"
else
  echo "⚠️  Missing Resources/AppIcon.icns — run: python3 scripts/make-icon.py"
fi

# Create PkgInfo
echo -n "APPLPSHT" > "$CONTENTS_DIR/PkgInfo"

# Code-sign with ad-hoc signature and entitlements
echo "✍️  Signing PinShot.app (Bundle ID: com.fable.PinShot)..."
codesign --force --deep --sign - --entitlements "$ROOT_DIR/Resources/Entitlements.plist" --identifier "com.fable.PinShot" "$APP_DIR"

echo "✅ PinShot.app built successfully!"
echo "👉 Run with: open $APP_DIR"

# ---------------------------------------------------------------------------
# 清掉「会跟本次产物混在一起的老副本」（2026-10-21 加，与 run-local.sh 同规则）：
#   · build/ 下的 .app 副本（历史遗留，本脚本不往那里写，但别人/老版本可能写）
#   · Xcode DerivedData 里本项目的缓存
# ⚠️ 刻意不删刚构建出来的 $APP_DIR —— 它就是这个脚本的唯一产物。
#    要装到 /Applications 并连同本地产物一起清干净，请用 run-local.sh。
# ---------------------------------------------------------------------------
echo "🧹 清理与本次产物无关的本地残留"
for d in "$ROOT_DIR"/build/*.app "$HOME/Library/Developer/Xcode/DerivedData/SnipShotBase-"*; do
  [ -e "$d" ] || continue
  rm -rf "$d" && echo "   🗑  已删除 ${d#$ROOT_DIR/}"
done

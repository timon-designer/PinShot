#!/usr/bin/env bash
# run-local.sh — 一键本地构建+打包+签名+运行 SnipShot
# 不用 Xcode GUI,涛哥只跑这一条命令就能测。
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="SnipShotBase"
APP_NAME="PinShot"          # 构建产物名（SPM target），不要改
DISPLAY_NAME="SnipShot"     # 对外显示名

# ⚠️ 千万不要改回 com.taoliu.snipshot
# macOS 26 会**按 bundle id 持久记住「这个 App 的菜单栏项目被隐藏」**。
# 一旦某个 id 被污染，同 id 的任何二进制都显示不出菜单栏图标 ——
# 换代码写法、换图标、延迟创建全都没用。唯一可靠解法就是换一个新 id。
# 代价：TCC 屏幕录制授权会重新记一次（首次启动需在系统设置里再勾一次）。
BUNDLE_ID="com.timon.snipshot"
OLD_BUNDLE_ID="com.taoliu.snipshot"   # 仅用于清理旧 id 的残留授权记录
# ⚠️ 不要在 ~/Library/Developer/DerivedData 下组装 .app —— 受限/沙箱环境里
# 该目录不可写，codesign 会直接报 "Operation not permitted"。放在项目内最稳。
APP_DIR="$(pwd)/build/${APP_NAME}.app"

echo "==> 0) 结束已在运行的旧实例（否则覆盖 .app 会失败/权限记录错乱）"
pkill -f "SnipShot.app/Contents/MacOS" 2>/dev/null || true
sleep 1

echo "==> 1) 编译 Release"
XCB_LOG="/tmp/snipshot_xcodebuild.log"
RAW=""
if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
     -scheme "$APP_NAME" -destination "platform=macOS" -configuration Release \
     -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/${PROJECT}-manual" build \
     >"$XCB_LOG" 2>&1; then
  RAW="$HOME/Library/Developer/Xcode/DerivedData/${PROJECT}-manual/Build/Products/Release/$APP_NAME"
  echo "    ✅ xcodebuild 完成（日志 ${XCB_LOG}）"
else
  # ⚠️ xcodebuild 解析 SPM 依赖时会 fork 一个 sandbox-exec 子进程。在沙箱/受限
  # 环境里「嵌套沙箱」会被内核拒绝（sandbox_apply: Operation not permitted），
  # 构建直接失败。swift build --disable-sandbox 不依赖 sandbox-exec，可绕过。
  # swift build 快很多（~15s vs 2~3min），想强制用它可设 SNIP_BUILD_ENGINE=swift。
  echo "    ⚠️  xcodebuild 失败：$(grep -m1 -E 'error[: ]' "$XCB_LOG" | sed 's/^[[:space:]]*//' || echo '未知原因')"
  echo "    ↳ 回退到 swift build --disable-sandbox"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swift build -c release --disable-sandbox
  RAW="$(pwd)/.build/release/$APP_NAME"
fi

if [ ! -f "$RAW" ]; then
  echo "!! 编译失败，未找到二进制：$RAW" >&2
  exit 1
fi

echo "==> 2) 组装 .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$RAW" "$APP_DIR/Contents/MacOS/$APP_NAME"

# 应用图标：Resources/AppIcon.icns → Contents/Resources/AppIcon.icns，
# 再由下面的 CFBundleIconFile 指过去。macOS 只在 bundle 里找 .icns，
# 不会去看源码目录 —— 漏了这一步，Info.plist 写了图标也不显示。
ICON_SRC="$(pwd)/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "    ✅ 图标已装入 Contents/Resources/AppIcon.icns"
else
  echo "    ⚠️  未找到 $ICON_SRC —— 图标会缺省。"
  echo "       生成方式: python3 scripts/make-icon.py"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>SnipShot 需要屏幕录制权限才能截图</string>
</dict>
</plist>
EOF

echo "==> 3) 签名 (固定身份 SnipShot Dev)"
codesign --force --deep --sign "SnipShot Dev" "$APP_DIR" 2>&1 | head -5
codesign -dvv "$APP_DIR" 2>&1 | grep -E "Authority|Identifier|CDHash" | head -5

# ---------------------------------------------------------------------------
# TCC（屏幕录制授权）重置策略
#
# ad-hoc 签名时代：签名身份为空，TCC 只能绑 cdhash，代码一改就失效 →
# 必须每次 reset 重授权。
#
# 现在有了固定签名身份 "SnipShot Dev"：TCC 的 csreq 里带上了稳定的
# certificate leaf，理论上授权可以跨重编保持。所以只在「签名身份变了」
# 或显式传 --reset-tcc 时才清记录，不再因为 cdhash 变化就无脑 reset。
# ---------------------------------------------------------------------------
NEW_CDHASH=$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)
NEW_AUTH=$(codesign -dvv "$APP_DIR" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' || true)
NEW_SIG="${NEW_AUTH:-<none>}|${NEW_CDHASH}"
STAMP_FILE=".last-signature"
OLD_SIG=$(cat "$STAMP_FILE" 2>/dev/null || echo "")
NEED_REGRANT=0

if [ "${1:-}" = "--reset-tcc" ]; then
  echo "    ↻ 显式要求重置 TCC 记录"
  tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null && echo "    ✅ TCC 记录已重置" || echo "    (重置失败，可忽略)"
  NEED_REGRANT=1
elif [ -n "$OLD_SIG" ] && [ "$OLD_SIG" != "$NEW_SIG" ]; then
  OLD_AUTH="${OLD_SIG%%|*}"
  if [ "$OLD_AUTH" != "${NEW_AUTH:-<none>}" ]; then
    echo "    ⚠️  签名身份已变化（$OLD_AUTH → ${NEW_AUTH:-<none>}），必须重新授权"
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
    NEED_REGRANT=1
  else
    echo "    ℹ️  签名身份未变（${NEW_AUTH}），仅 cdhash 变化 → 保留 TCC 授权"
  fi
fi
printf '%s' "$NEW_SIG" > "$STAMP_FILE"

echo "==> 4) 清掉可能的隔离属性 + quarantine"
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "==> 4.5) 清理旧 bundle id ($OLD_BUNDLE_ID) 的残留授权记录"
if tccutil reset ScreenCapture "$OLD_BUNDLE_ID" >/dev/null 2>&1; then
  echo "    OK-4.5 已清理旧 id 的屏幕录制记录"
else
  echo "    OK-4.5 无旧记录或清理失败（可忽略）"
fi

echo "==> 5) 安装到 /Applications (系统设置隐私页能直接看到这个 app)"
mkdir -p "$HOME/Applications"
rm -rf "/Applications/SnipShot.app" "$HOME/Applications/SnipShot.app"
cp -R "$APP_DIR" "/Applications/SnipShot.app"
INSTALLED="/Applications/SnipShot.app"

echo ""
echo "✅ 已安装: $INSTALLED"
echo "    ↳ 安装后自校验（防止「构建成功但装的是旧版本」）:"
INSTALLED_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo "?")
INSTALLED_HASH=$(codesign -dv --verbose=4 "$INSTALLED" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)
BUILT_HASH=$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)
echo "       bundle id : $INSTALLED_ID"
echo "       已装 CDHash: $INSTALLED_HASH"
echo "       本次 CDHash: $BUILT_HASH"
if [ "$INSTALLED_ID" != "$BUNDLE_ID" ]; then
  echo "    ❌ bundle id 不匹配！安装没有真正生效。"
  exit 1
fi
if [ "$INSTALLED_HASH" != "$BUILT_HASH" ]; then
  echo "    ❌ CDHash 不一致！装上去的不是本次构建产物。"
  exit 1
fi
echo "    ✅ 校验通过：装上去的就是本次构建的二进制"

# 图标自校验：Info.plist 指了名 + Resources 里真有这个文件，两者缺一不可。
# 只写 CFBundleIconFile 而忘了拷 .icns，是最容易静默失败的组合（图标不显示但不报错）。
ICON_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo "")
if [ -z "$ICON_NAME" ]; then
  echo "    ⚠️  Info.plist 里没有 CFBundleIconFile → Finder 里会是通用图标"
elif [ ! -f "$INSTALLED/Contents/Resources/${ICON_NAME}.icns" ]; then
  echo "    ❌ CFBundleIconFile=$ICON_NAME 但 Contents/Resources/${ICON_NAME}.icns 不存在！"
  exit 1
else
  echo "    ✅ 图标校验通过：CFBundleIconFile=$ICON_NAME → Contents/Resources/${ICON_NAME}.icns ($(stat -f%z "$INSTALLED/Contents/Resources/${ICON_NAME}.icns") bytes)"
fi

# ---------------------------------------------------------------------------
# 5.9) 清理本地构建残留（涛哥要求，2026-10-21 加）
#
# 走到这一步，新版本已经装进 /Applications 且 CDHash 校验通过。
# 项目内 build/*.app 和 Xcode DerivedData 里剩下的都是「同名旧副本」——
# 留着唯一的作用是让人手滑点到老版本，一律清掉。
# ⚠️ 必须在「CDHash / 图标校验」之后执行：那些校验读的就是 $APP_DIR。
# ---------------------------------------------------------------------------
echo "==> 5.9) 清理本地 .app 副本与 DerivedData 缓存"
for d in "$(pwd)"/build/*.app "$(pwd)"/*.app; do
  [ -d "$d" ] || continue
  rm -rf "$d" 2>/dev/null || true
  [ -d "$d" ] && echo "    ⚠️  删除受阻（权限/沙箱），请手动删：$d" || echo "    🗑  已删除 ${d#$(pwd)/}"
done
for d in "$HOME/Library/Developer/Xcode/DerivedData/${PROJECT}-"* \
         "$HOME/Library/Developer/Xcode/DerivedData/${APP_NAME}-"*; do
  [ -d "$d" ] || continue
  rm -rf "$d" 2>/dev/null || true
  [ -d "$d" ] && echo "    ⚠️  删除受阻（权限/沙箱），请手动删：$d" || echo "    🗑  已删除 DerivedData/$(basename "$d")"
done
echo "    ℹ️  本机只保留 /Applications/SnipShot.app 这一份，不会被误触老版本"

echo ""
echo "📋 诊断日志: /tmp/snipshot.log"
echo "    · 「菜单栏: ✅ 已贴在菜单栏上」 = 图标正常"
echo "    · 「Capture: ✅ 遮罩已显示」    = 截图流程正常"
echo ""
echo "📌 屏幕录制授权（macOS 26 必读）"
echo "   macOS 26 不会给自签名 App 自动弹授权提示，也不会自动写进列表。"
echo "   必须手动添加一次（添加后开关会自动打开，之后重建也不会丢）："
echo "   1. 系统设置 → 隐私与安全性 → 录屏与系统录音"
echo "   2. 点列表下方的 ＋ → 在「应用程序」里选中 SnipShot.app → 打开"
echo "   3. 若列表里已有 SnipShot，直接打开它的开关即可"
echo "   （授权绑定的是证书身份，不是 CDHash，所以以后重新构建无需再授权）"

echo "==> 6) 直接启动 (后台)"
open "$INSTALLED"
sleep 2
echo ""
echo "运行中进程 (PID):"
pgrep -f "/Applications/SnipShot.app/Contents/MacOS/$APP_NAME" || echo "(未检测到,启动可能失败)"
echo ""
echo "▶ 现在你可以:"
echo "   • 默认热键 ⌘⇧A 开始截图"
echo "   • 菜单栏看到一个取景框小图标 = 正在运行"
echo "   • 重新构建(改完代码后): bash run-local.sh"

#!/usr/bin/env bash
# verify-pin.sh —— 贴图（Pin 窗口）拖动 / 缩放的无头验收套件
#
# 为什么需要它：贴图交互属于 GUI 行为，改完代码肉眼看一眼很容易漏。
# 这里用合成事件（CGEvent）+ 量窗口几何（CGWindowList）做**可重复的机器验收**，
# 不需要人动手，改完随时 `bash scripts/verify-pin.sh` 确认没回归。
#
# 覆盖：按住任意位置拖动（含留白圈/圆角）/ 滚轮以鼠标为锚点缩放 / ⌥细调 / ⇧粗调 /
#       应用失活（贴图浮在别的 App 上）时仍然可拖可缩 / 双击关闭与右键菜单未被破坏。
#
# 依赖：本机 Accessibility 授权（合成事件需要；`AXIsProcessTrusted()` 为 true 即可）。
set -uo pipefail
cd "$(dirname "$0")"
PROJ="$(cd .. && pwd)"
TOOL="$(pwd)/pinstate"
APP="/Applications/SnipShot.app"
LOG="/tmp/snipshot.log"

if [ ! -x "$TOOL" ]; then
  echo "==> 首次运行：编译事件合成工具 pinstate"
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  SDK="$(xcrun --show-sdk-path --sdk macosx)"
  "$(xcrun -f swiftc)" -O -target arm64-apple-macos14.0 -sdk "$SDK" \
    "$(pwd)/pinstate.swift" -o "$TOOL" || { echo "!! 编译失败"; exit 1; }
fi

[ -d "$APP" ] || { echo "!! 未找到 ${APP}，先跑 bash run-local.sh"; exit 1; }

P="$TOOL"; PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }
pin(){ $P pin; }

pkill -f "SnipShot.app/Contents/MacOS" 2>/dev/null; sleep 1.2
open "$APP"; sleep 2.5
$P activate >/dev/null; sleep 1
$P hotkey >/dev/null; sleep 1.6
$P drag 300 200 760 520 >/dev/null; sleep 1.4
$P key 35 >/dev/null; sleep 1.8
read -r X Y W H <<< "$(pin)"
if [ "$X" = "NONE" ]; then echo "❌ 贴图未创建（检查屏幕录制权限）"; exit 1; fi
echo "═ 贴图 X=$X Y=$Y W=$W H=$H  (glowPadding=16 + 圆角 10)"
echo ""

echo "═ 验收① 按住【任意位置】都能拖动 ══"
d(){ read -r cx cy cw ch <<< "$(pin)"
     local tx=$((cx+$2)) ty=$((cy+$3))
     $P drag $tx $ty $((tx+$4)) $((ty+$5)) >/dev/null; sleep 0.9
     read -r nx ny nw nh <<< "$(pin)"
     if [ "$((nx-cx))" = "$4" ] && [ "$((ny-cy))" = "$5" ]; then ok "$1 Δ=($4,$5)"
     else no "$1 Δ=($((nx-cx)),$((ny-cy))) 期望($4,$5)"; fi; }
read -r cx cy cw ch <<< "$(pin)"
d "留白圈·左上  " 3 3 40 30
d "留白圈·顶边  " $((cw/2)) 4 40 30
d "留白圈·左中  " 4 $((ch/2)) 40 30
d "圆角附近     " 19 19 40 30
d "图片左上     " 40 40 -60 -45
d "图片正中     " $((cw/2)) $((ch/2)) 120 90
d "图片右下     " $((cw-24)) $((ch-24)) -55 65

echo ""
echo "═ 验收② 滚轮缩放（鼠标锚点 / ⌥细调 / ⇧粗调）══"
read -r cx cy cw ch <<< "$(pin)"
PX=$(awk "BEGIN{printf \"%.0f\", $cx+$cw*0.35}"); PY=$(awk "BEGIN{printf \"%.0f\", $cy+$ch*0.35}")
OW=$cw; OX=$cx
$P scroll "$PX" "$PY" 3 none >/dev/null; sleep 1.0
read -r nx ny nw nh <<< "$(pin)"
PLAIN=$((nw-OW))
echo "  滚轮向上: W $OW → $nw (Δ=$PLAIN)"
[ "$nw" -gt "$OW" ] && ok "滚轮向上 = 放大" || no "滚轮方向错"
R1=$(awk "BEGIN{printf \"%.3f\",($PX-$OX)/$OW}"); R2=$(awk "BEGIN{printf \"%.3f\",($PX-$nx)/$nw}")
A=$(awk "BEGIN{d=($R2-$R1);if(d<0)d=-d;print (d<0.02)?\"OK\":\"BAD\"}")
[ "$A" = "OK" ] && ok "以鼠标为锚点，光标下像素不跳位（rel ${R1}→${R2}）" || no "锚点漂移 ${R1}→$R2"
OW=$nw
$P scroll "$PX" "$PY" -3 none >/dev/null; sleep 1.0
read -r nx ny nw nh <<< "$(pin)"
[ "$nw" -lt "$OW" ] && ok "滚轮向下 = 缩小" || no "向下不缩小"
OW=$nw
$P scroll "$PX" "$PY" 3 opt >/dev/null; sleep 1.0
read -r ox oy ow oh <<< "$(pin)"
FINE=$(awk "BEGIN{printf \"%.1f\",$ow-$OW}")
echo "  ⌥+向上: $OW → $ow (Δ=$FINE) ／ 普通档 Δ=$PLAIN"
awk "BEGIN{exit !($FINE>0 && $FINE<$PLAIN)}" && ok "⌥ = 细调" || no "⌥ 细调失效"
OW=$ow
$P scroll "$PX" "$PY" 3 shift >/dev/null; sleep 1.0
read -r sx sy sw sh <<< "$(pin)"
COARSE=$(awk "BEGIN{printf \"%.1f\",$sw-$OW}")
echo "  ⇧+向上: $OW → $sw (Δ=$COARSE)   [macOS 会把 ⇧+滚轮转成横向滚动]"
awk "BEGIN{exit !($COARSE>$FINE && $COARSE>0)}" && ok "⇧ = 粗调" || no "⇧ 粗调失效"

echo ""
echo "═ 验收①-b 应用失活（贴图浮在别的 App 上）══"
$P deactivate >/dev/null; sleep 1.5
read -r bx by bw bh <<< "$(pin)"
bx2=$(awk "BEGIN{printf \"%.0f\",$bx+$bw*0.35}"); by2=$(awk "BEGIN{printf \"%.0f\",$by+$bh*0.35}")
$P drag "$bx2" "$by2" $((bx2-110)) $((by2-75)) >/dev/null; sleep 1.1
read -r ax ay aw ah <<< "$(pin)"
[ "$((ax-bx))" = "-110" ] && [ "$((ay-by))" = "-75" ] \
  && ok "失活态可拖动（一次点击直接拖，不需先点一下）" \
  || no "失活态 Δ=($((ax-bx)),$((ay-by)))"
OW=$bw
$P scroll "$bx2" "$by2" 3 none >/dev/null; sleep 1.0
read -r ax ay aw ah <<< "$(pin)"
[ "$aw" != "$OW" ] && ok "失活态可滚轮缩放（${OW}→${aw}）" || no "失活态滚轮失效"

echo ""
echo "═ 回归：SwiftUI 交互未被拖窗逻辑破坏 ══"
$P activate >/dev/null; sleep 1
read -r gx gy gw gh <<< "$(pin)"
gcx=$(awk "BEGIN{printf \"%.0f\",$gx+$gw/2}"); gcy=$(awk "BEGIN{printf \"%.0f\",$gy+$gh/2}")
$P dblclick "$gcx" "$gcy" >/dev/null; sleep 1.2
[ "$(pin)" = "NONE" ] && ok "双击空白处 = 关闭贴图" || no "双击关闭失效"
$P hotkey >/dev/null; sleep 1.5; $P drag 300 200 700 480 >/dev/null; sleep 1.3
$P key 35 >/dev/null; sleep 1.6
read -r qx qy qw qh <<< "$(pin)"
qcx=$(awk "BEGIN{printf \"%.0f\",$qx+$qw/2}"); qcy=$(awk "BEGIN{printf \"%.0f\",$qy+$qh/2}")
$P rclick "$qcx" "$qcy" >/dev/null; sleep 1.0
read -r zx zy zw zh <<< "$(pin)"
[ "$zx" = "$qx" ] && ok "右键只弹菜单、不误拖动" || no "右键误触发拖动"
$P key 53 >/dev/null; sleep 0.6

echo ""
echo "═ 结果：通过 $PASS ／ 失败 $FAIL ══"
echo "  应用日志: ${LOG}（grep 'Pin:' 看拖动/滚轮实时事件）"
[ "$FAIL" -eq 0 ] || exit 1

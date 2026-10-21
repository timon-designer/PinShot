#!/usr/bin/env bash
# install-cert.sh — 把项目内 .cert/ 下的 SnipShot Dev 证书装到钥匙串,
# 适用于:机器重装、迁移、新工作机.
set -euo pipefail

cd "$(dirname "$0")"
CERT_DIR=".cert"
KEY="$CERT_DIR/snip.key"
CRT="$CERT_DIR/snip.crt"

if [ ! -f "$KEY" ] || [ ! -f "$CRT" ]; then
  echo "❌ 缺证书文件: $KEY 或 $CRT" >&2
  exit 1
fi

KC="$HOME/Library/Keychains/login.keychain-db"

echo "==> 删除旧的 SnipShot Dev 身份(如有)"
security delete-identity -c "SnipShot Dev" "$KC" 2>/dev/null || true
security delete-certificate -c "SnipShot Dev" "$KC" 2>/dev/null || true

echo "==> 导入私钥"
security import "$KEY" -k "$KC" -A 2>&1 | head -3
echo "==> 导入证书 (会让钥匙串弹窗一次:始终允许)"
security import "$CRT" -k "$KC" -A -T /usr/bin/codesign 2>&1 | head -3

echo "==> 设为代码签名信任根"
security add-trusted-cert -d -r trustRoot -p codeSign "$CRT" 2>&1 | head -3 || true

echo "==> 验证"
security find-identity -p codesigning -v "$KC" | grep "SnipShot Dev" || {
  echo "❌ identity 不可见" >&2
  exit 1
}

echo ""
echo "✅ 证书已安装"
echo ""
echo "⚠️ 首次 codesign 时会弹「允许 codesign 访问'始终允许' SnipShot Dev 吗?」"
echo "   点「始终允许」→ 以后跑 build 都不会再弹"

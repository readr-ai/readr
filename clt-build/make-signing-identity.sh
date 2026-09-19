#!/bin/bash
#
# 建一个固定的本地签名身份，让每次重建的 app 都签在同一个身份下。
#
# 为什么需要它：ad-hoc 签名（`codesign --sign -`）的权限判据是**这次构建的 CDHash**，
# 重建一次就变一次。Readr 的 API key 存在 Keychain 里，Keychain 的允许名单记的是
# 权限判据 —— 所以每次重建后第一次启动都会弹一次「Readr 想使用钥匙串中的密钥」，
# 而那个框一旦没人点，app 会卡在读钥匙串那一步、连窗口都不出来（踩过一次，很贵）。
#
# 用固定证书之后，权限判据变成 `identifier "com.readrai.app" and certificate root = H"…"`,
# 只跟证书有关、跟构建无关。于是：授权一次，以后都不再问。
#
# 用法：
#   ./clt-build/make-signing-identity.sh          # 建（已存在则跳过）
#   ./clt-build/make-signing-identity.sh --force  # 重建证书
#
# 产物（都在 iCloud 同步范围之外）：
#   ~/Library/Keychains/readr-signing.keychain-db      专用钥匙串，只装这一张证书
#   ~/.readr-signing.keychain-password                 它的密码，600 权限
#
# 证书是自签名的、2036 年到期、只用于本机。它没被加入系统信任（那需要管理员密码），
# 也不需要：`codesign --verify` 对自签名链是能通过的，本地运行也从不检查这个。
# 它不授予任何超出本机开发的东西。

set -euo pipefail

IDENTITY="Readr Local Build"
KEYCHAIN="${READR_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/readr-signing.keychain-db}"
PASSWORD_FILE="${READR_SIGNING_PASSWORD_FILE:-$HOME/.readr-signing.keychain-password}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ -e "$KEYCHAIN" ] && [ "$FORCE" -eq 0 ]; then
  if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "已存在: $KEYCHAIN 里的 \"$IDENTITY\"（要重建设 --force）"
    exit 0
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = Readr Local Build
O = Local Development

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> 生成自签名证书（10 年）"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" >/dev/null 2>&1
P12_PASS="$(openssl rand -hex 12)"
openssl pkcs12 -export -out "$WORK/cert.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$P12_PASS" >/dev/null 2>&1

echo "==> 准备专用钥匙串"
# 密码随机生成并存进 600 权限的文件：钥匙串里只有这张证书，密码只用于解锁它自己，
# 不借它做任何别的事，所以这不是「把登录钥匙串密码写在磁盘上」。
if [ ! -e "$PASSWORD_FILE" ]; then
  printf '%s' "$(openssl rand -hex 16)" > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
fi
PW="$(cat "$PASSWORD_FILE")"

if [ -e "$KEYCHAIN" ] && [ "$FORCE" -eq 1 ]; then
  if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    security delete-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
fi
if [ ! -e "$KEYCHAIN" ]; then
  security create-keychain -p "$PW" "$KEYCHAIN"
fi
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PW" "$KEYCHAIN"

echo "==> 导入"
# -T 把 codesign / security 列为允许使用私钥的程序，配合 set-key-partition-list，
# 签名时不会再弹「codesign 想使用钥匙串中的密钥」。
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null

echo "==> 加入钥匙串搜索列表"
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
if ! printf '%s\n' "$EXISTING" | grep -qx "$KEYCHAIN"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

echo "==> 自检：签一个临时文件，看身份判据"
cp /bin/echo "$WORK/probe"
if codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$WORK/probe" 2>/dev/null; then
  codesign -d -r- "$WORK/probe" 2>&1 | grep designated || true
  echo "    好了。它只跟证书有关 —— 重建多少次都不变，钥匙串问一次就够。"
else
  echo "    ✗ 签名失败"; exit 1
fi

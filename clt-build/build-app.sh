#!/bin/bash
#
# 只用 Command Line Tools 构建 Readr.app —— 不需要完整 Xcode。
#
#   ./clt-build/build-app.sh            # debug（快，默认）
#   ./clt-build/build-app.sh release    # 优化版，慢一些
#
# 成品装在 $HOME/Applications/Readr.app（可用 INSTALL_DIR=... 覆盖），可直接双击。
# 中间产物（未安装的二进制）在 clt-build/build/。
#
# 为什么需要这条路径：仓库里的 app 是 Xcode 工程（project.yml → xcodegen →
# xcodebuild），而只有 Command Line Tools 的机器上 xcodebuild 会直接拒绝
# （"requires Xcode, but active developer directory ... is a command line tools
# instance"）。这条脚本绕开 Xcode：
#   1. ReadrKit 用 SwiftPM 编译（纯 Swift，无第三方依赖）
#   2. ZIPFoundation 从 GitHub 取指定 tag，编译成静态库
#   3. App/ 下的源码用 swiftc 直接编译，并链接上面的产物
#   4. 手工组装 .app（Info.plist + iconutil 生成 .icns + 资源）+ 签名
#
# 签名默认用固定的本地身份（先跑一次 ./clt-build/make-signing-identity.sh 建它）；
# 没有就退回 ad-hoc 签名。为什么值得建：见第 5 步那段注释 —— ad-hoc 会让 Keychain
# 每次重建后都问一次授权，且可能把 app 卡在启动阶段。
#
# 两个必须知道的坑：
#   * SwiftPM 编译/运行 manifest 时会调 sandbox-exec，在受限环境里报
#     "sandbox-exec: sandbox_apply: Operation not permitted"，并伪装成
#     "Invalid manifest"（跟代码无关，极易误判）。所以这里一律加 --disable-sandbox。
#   * App/Speech/KokoroSpeechEngine.swift 里对 FluidAudio（CoreML Kokoro）的引用被
#     `#if canImport(FluidAudio)` 守卫着，本脚本不提供该包，所以构建出的 app
#     用系统语音朗读（"Readr Voice" 不可用），阅读/提问/DeepSeek 等其余功能完整。
#     Xcode 完整构建不受影响，仍然带 Readr Voice。
#
set -euo pipefail

CONFIG="${1:-debug}"
case "$CONFIG" in
  debug)   SWIFT_FLAGS=(-Onone -g) ;;
  release) SWIFT_FLAGS=(-O) ;;
  *) echo "用法: $0 [debug|release]"; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$SCRIPT_DIR/build"
CACHE="$SCRIPT_DIR/.cache"
ZIPFOUNDATION_TAG="0.9.19"

cd "$REPO"

SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos14.0"   # 工程本身排除了 x86_64（见 project.yml EXCLUDED_ARCHS）

# 不清空 ${BUILD}：里面的 dSYM 有 45+ 个文件，rm -rf 会撞上批量删除保护（脚本在
# 无人应答时停在那里）。swiftc 覆盖二进制、dsymutil 重建 dSYM，不清也一样对。
mkdir -p "$BUILD" "$CACHE"

# 组装与签名都在一个未被同步的临时目录里做，最后再拷回来。
#
# 原因（踩过一次）：这台机器的桌面在 iCloud Drive 同步范围内，构建目录又在桌面下，
# 同步代理会随时给 bundle 重新贴上 com.apple.FinderInfo。codesign 见到它就直接拒绝
# ——"resource fork, Finder information, or similar detritus not allowed"——
# 结果是"看起来签过、其实没签"（包内没有 _CodeSignature），Keychain 相关功能全受影响。
# 改在 ${TMPDIR}（/var/folders/...，永不被同步）里签名，就没有这个竞态。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Readr.app"

# ---------------------------------------------------------------- 1. ReadrKit
echo "==> [1/5] 编译 ReadrKit（SwiftPM）"
swift build -c "$CONFIG" --disable-sandbox >/dev/null
KIT_MODULES=".build/$CONFIG/Modules"
KIT_OBJECTS=(".build/$CONFIG/ReadrKit.build/"*.o)
if [ ! -d "$KIT_MODULES" ] || [ ! -e "${KIT_OBJECTS[0]}" ]; then
  echo "    ✗ 找不到 ReadrKit 产物（${KIT_MODULES}）"; exit 1
fi
echo "    $(ls .build/$CONFIG/ReadrKit.build/*.o | wc -l | tr -d ' ') 个目标文件"

# --------------------------------------------------------- 2. ZIPFoundation
ZIP_SRC="$CACHE/ZIPFoundation"
echo "==> [2/5] 取并编译 ZIPFoundation $ZIPFOUNDATION_TAG"
if [ ! -d "$ZIP_SRC" ]; then
  git clone --depth 1 --branch "$ZIPFOUNDATION_TAG" \
    https://github.com/weichsel/ZIPFoundation "$ZIP_SRC" >/dev/null 2>&1
fi
swiftc -parse-as-library -emit-library -static \
  -module-name ZIPFoundation \
  -emit-module-path "$CACHE/ZIPFoundation.swiftmodule" \
  -o "$CACHE/libZIPFoundation.a" \
  -sdk "$SDK" -target "$TARGET" \
  "$ZIP_SRC/Sources/ZIPFoundation/"*.swift

# ------------------------------------------------------------- 3. App 本体
echo "==> [3/5] 编译链接 App 源码"
# App/**/*.swift 全量编译；平台不适用的部分本来就带 #if 守卫
# （MLXKokoroSpeechEngine 是 #if os(iOS)，KokoroSpeechEngine 走上面的 canImport 分支）
swiftc "${SWIFT_FLAGS[@]}" -o "$BUILD/Readr" \
  -sdk "$SDK" -target "$TARGET" \
  -I "$CACHE" -I "$KIT_MODULES" \
  $(find App -name '*.swift') \
  "${KIT_OBJECTS[@]}" \
  -L "$CACHE" -lZIPFoundation

# ------------------------------------------------------------- 4. 组装 app
echo "==> [4/5] 组装 Readr.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Readr" "$APP/Contents/MacOS/Readr"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Info.plist 从模板生成，版本号跟 project.yml 对齐
MARKETING_VERSION="$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\([^"]*\)".*/\1/')"
BUILD_NUMBER="$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*"\([^"]*\)".*/\1/')"
sed -e "s/__VERSION__/${MARKETING_VERSION:-3.3.1}/" \
    -e "s/__BUILD__/${BUILD_NUMBER:-1}/" \
    "$SCRIPT_DIR/Info.plist" > "$APP/Contents/Info.plist"

# 图标：用 asset catalog 里现成的 mac 各尺寸拼 .icns（省掉 Xcode 的 actool）
# 图标：用 asset catalog 里现成的 mac 各尺寸拼 .icns（不需要 Xcode 的 actool）。
# iconset 建在本次构建自己的临时目录里（${WORK}，EXIT 时整棵删掉）：固定路径 +
# 每次 rm -rf 会在有批量删除保护的环境里卡住确认，而且残留下来的半套 iconset
# 只会让 iconutil 的输出变得不可信。
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC="App/Assets.xcassets/AppIcon.appiconset"
cp "$SRC/mac-16x16@1x.png"   "$ICONSET/icon_16x16.png"
cp "$SRC/mac-16x16@2x.png"   "$ICONSET/icon_16x16@2x.png"
cp "$SRC/mac-32x32@1x.png"   "$ICONSET/icon_32x32.png"
cp "$SRC/mac-32x32@2x.png"   "$ICONSET/icon_32x32@2x.png"
cp "$SRC/mac-128x128@1x.png" "$ICONSET/icon_128x128.png"
cp "$SRC/mac-128x128@2x.png" "$ICONSET/icon_128x128@2x.png"
cp "$SRC/mac-256x256@1x.png" "$ICONSET/icon_256x256.png"
cp "$SRC/mac-256x256@2x.png" "$ICONSET/icon_256x256@2x.png"
cp "$SRC/mac-512x512@1x.png" "$ICONSET/icon_512x512.png"
cp "$SRC/mac-512x512@2x.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 资源：首次启动播种的示例书 + 隐私清单
cp App/Resources/alice-in-wonderland.epub "$APP/Contents/Resources/"
cp App/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"

# --------------------------------------------------------------- 5. 签名并安装
#
# 优先用固定的本地身份（`make-signing-identity.sh` 建的），没有才退回 ad-hoc。
#
# 这不是讲究：ad-hoc 签名的权限判据是**这次构建的 CDHash**，重建一次变一次，而
# Readr 的 API key 在 Keychain 里 —— 于是每次重建后第一次启动都要弹一次授权框，
# 一旦没人点，app 就卡在读钥匙串那一步、连窗口都不出来（踩过，排查了一小时）。
# 固定证书把判据换成 `identifier "com.readrai.app" and certificate root = H"…"`，
# 只跟证书有关，授权一次以后就不再问。
SIGNING_KEYCHAIN="${READR_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/readr-signing.keychain-db}"
SIGNING_IDENTITY="${READR_SIGNING_IDENTITY:-Readr Local Build}"
SIGNING_PASSWORD_FILE="${READR_SIGNING_PASSWORD_FILE:-$HOME/.readr-signing.keychain-password}"
SIGN_ARGS=(--sign -)
SIGN_LABEL="ad-hoc"
if [ -e "$SIGNING_KEYCHAIN" ] \
   && security find-certificate -c "$SIGNING_IDENTITY" "$SIGNING_KEYCHAIN" >/dev/null 2>&1; then
  if [ -e "$SIGNING_PASSWORD_FILE" ]; then
    security unlock-keychain -p "$(cat "$SIGNING_PASSWORD_FILE")" "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  SIGN_ARGS=(--sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN")
  SIGN_LABEL="$SIGNING_IDENTITY"
fi
echo "==> [5/5] 签名（${SIGN_LABEL}）并安装"
xattr -cr "$APP" 2>/dev/null || true
# Clear-then-sign with retries: an xattr re-attached between the two steps is the
# one failure mode seen in practice, and it costs nothing to try again.
signed=0
for attempt in 1 2 3; do
  if codesign --force --deep "${SIGN_ARGS[@]}" "$APP" 2>"$CACHE/codesign.log" \
     && codesign --verify --deep --strict "$APP" 2>>"$CACHE/codesign.log"; then
    signed=1
    break
  fi
  xattr -cr "$APP" 2>/dev/null || true
done
if [ "$signed" -ne 1 ]; then
  echo "    ✗ 签名失败："; tail -3 "$CACHE/codesign.log"; exit 1
fi
if [ "$SIGN_LABEL" != "ad-hoc" ]; then
  # 打出权限判据：它必须只跟证书有关。若这里出现 cdhash，说明签的根本不是固定身份，
  # 钥匙串那次授权就会在下次重建后失效 —— 早发现比用户发现好。
  DR="$(codesign -d -r- "$APP" 2>&1 | grep designated || true)"
  echo "    判据: ${DR#designated => }"
  case "$DR" in
    *cdhash*) echo "    ⚠️ 判据里出现 cdhash：这次不是固定身份签的，钥匙串授权会失效" ;;
  esac
fi

# 装到 $HOME/Applications：它不在 iCloud 的同步范围内。
#
# 这一条是实测出来的，不是讲究：本仓库位于 ~/Desktop，而系统/iCloud 的
# "桌面与文档"同步一旦开启，同步代理会随时给目录贴回 com.apple.FinderInfo，
# codesign 见到就拒绝（"resource fork, Finder information, or similar detritus
# not allowed"）。留在仓库构建目录里的那份，签名必然会被后续同步打断
# ——codesign --verify 报 "Disallowed xattr com.apple.FinderInfo found"——而
# Readr 的 API key 存在 Keychain 里，签名不成立会牵动钥匙串访问。
# 所以中间产物留在 build/，能跑的成品装在 $HOME/Applications。
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$INSTALL_DIR"
INSTALLED="$INSTALL_DIR/Readr.app"
# 上一份构建移进废纸篓，而不是 rm -rf 掉：一个 .app 有 50+ 个文件，直接删在带
# 批量删除保护的环境里会卡在确认上（脚本在无人应答时停住），而进废纸篓既不触发
# 保护、又能让你在发现新版不对劲时把上一份拿回来。
if [ -e "$INSTALLED" ]; then
  mkdir -p "$HOME/.Trash"
  mv "$INSTALLED" "$HOME/.Trash/Readr-$(date +%Y%m%d-%H%M%S).app"
fi
# ditto 保留签名；--noextattr/--noqtn 把扩展属性挡在门外，别把脏东西带过去。
ditto --noextattr --noqtn "$APP" "$INSTALLED"
codesign --verify --deep --strict "$INSTALLED" \
  || { echo "    ✗ 安装后签名校验失败"; exit 1; }

echo "==> 完成"
echo "    可直接双击运行: $INSTALLED"
echo "    中间产物（未安装的二进制）: $BUILD/Readr"

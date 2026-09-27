#!/bin/bash
# Berth DMG 打包脚本:xcodegen → Release 构建(自动选签名)→ create-dmg → 可选公证。
#
# 用法:
#   ./scripts/package_dmg.sh                    # 出 Berth-<版本>.dmg 到 build/
#   NOTARY_PROFILE=berth ./scripts/package_dmg.sh  # 构建后顺带公证 + 装订(需先
#                                               # xcrun notarytool store-credentials)
#
# 签名自动选择:
#   - 钥匙串里有 "Developer ID Application" 证书 → 用它签名并开启 hardened runtime
#     (公证的硬性要求),走 Developer ID 发布形态
#   - 没有证书 → ad-hoc 签名,只适合本机/测试分发(Gatekeeper 对外来机器会拦,
#     需右键打开;iCloud/钥匙串共享等依赖 team 前缀的 entitlement 不生效)
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺 xcodegen(brew install xcodegen)"; exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "缺 create-dmg(brew install create-dmg)"; exit 1
fi

VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | awk '{print $2}' | tr -d '"')"
APP_NAME="Berth"
OUT_DIR="build"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGE_DIR="${OUT_DIR}/stage"

echo "==> 打包 ${APP_NAME} ${VERSION}"

# 1) 工程文件不入库,先重新生成
xcodegen generate

# 2) 选签名身份
HARDENED_RUNTIME=NO
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  SIGN_IDENTITY="Developer ID Application"
  HARDENED_RUNTIME=YES
  echo "==> 签名:Developer ID Application(hardened runtime 开)"
else
  SIGN_IDENTITY="-"
  echo "==> 签名:ad-hoc(未发现 Developer ID 证书,产物仅供本机/测试使用)"
fi

# 3) Release 构建。公证要求 hardened runtime,无证书时保持项目默认
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${OUT_DIR}/DerivedData" \
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
  ENABLE_HARDENED_RUNTIME="${HARDENED_RUNTIME}" \
  build

APP_PATH="${OUT_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"
[ -d "${APP_PATH}" ] || { echo "构建产物缺失: ${APP_PATH}"; exit 1; }

# 4) 组装 DMG:应用 + 指向 Applications 的软链
rm -rf "${STAGE_DIR}" "${OUT_DIR}/${DMG_NAME}"
mkdir -p "${STAGE_DIR}"
cp -R "${APP_PATH}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

create-dmg \
  --volname "${APP_NAME} ${VERSION}" \
  --window-size 580 380 \
  --icon-size 96 \
  --icon "${APP_NAME}.app" 140 170 \
  --app-drop-link 440 170 \
  --hide-extension "${APP_NAME}.app" \
  "${OUT_DIR}/${DMG_NAME}" \
  "${STAGE_DIR}"
rm -rf "${STAGE_DIR}"

# 5) 可选公证:NOTARY_PROFILE 指向 notarytool store-credentials 存好的凭据
if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ "${HARDENED_RUNTIME}" != "YES" ]; then
    echo "!! 无 Developer ID 证书,跳过公证"; exit 0
  fi
  echo "==> 提交公证(Apple 服务器通常几分钟,最长可等 30 分钟)"
  xcrun notarytool submit "${OUT_DIR}/${DMG_NAME}" \
    --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun notarytool staple "${OUT_DIR}/${DMG_NAME}"
  echo "==> 公证完成"
fi

echo "==> 完成: ${REPO_ROOT}/${OUT_DIR}/${DMG_NAME}"

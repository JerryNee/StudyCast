#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${RELEASE_VERSION:?Set RELEASE_VERSION, for example 0.1.0-beta.2}"
: "${UXPLAY_SOURCE_DIR:?Set UXPLAY_SOURCE_DIR to the exact UxPlay source tree used for this release}"
: "${UXPLAY_COMMIT:?Set UXPLAY_COMMIT to the exact UxPlay commit used for this release}"

SIGNING_MODE="${SIGNING_MODE:-developer-id}"
case "${SIGNING_MODE}" in
  developer-id)
    : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity}"
    : "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to an xcrun notarytool keychain profile}"
    DMG_SUFFIX="arm64"
    ;;
  adhoc)
    DMG_SUFFIX="arm64-unsigned"
    ;;
  *)
    echo "invalid SIGNING_MODE: ${SIGNING_MODE}; use developer-id or adhoc" >&2
    exit 64
    ;;
esac

"${SCRIPT_DIR}/bootstrap_release_deps.sh"

BUILD_ROOT="${REPO_ROOT}/build/release"
ARCHIVE_PATH="${BUILD_ROOT}/StudyCast.xcarchive"
EXPORT_DIR="${BUILD_ROOT}/export"
STAGING_DIR="${BUILD_ROOT}/dmg-staging"
ASSETS_DIR="${BUILD_ROOT}/assets"
APP_PATH="${EXPORT_DIR}/StudyCast.app"
DMG_PATH="${ASSETS_DIR}/StudyCast-${RELEASE_VERSION}-${DMG_SUFFIX}.dmg"
SOURCE_TARBALL="${ASSETS_DIR}/StudyCast-${RELEASE_VERSION}-source.tar.gz"
UXPLAY_TARBALL="${ASSETS_DIR}/UxPlay-${UXPLAY_COMMIT}-source.tar.gz"

rm -rf "${BUILD_ROOT}"
mkdir -p "${EXPORT_DIR}" "${STAGING_DIR}" "${ASSETS_DIR}"

pushd "${REPO_ROOT}" >/dev/null

xcodebuild \
  -project StudyCast.xcodeproj \
  -scheme StudyCast \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "${ARCHIVE_PATH}" \
  clean archive \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  UXPLAY_SOURCE_DIR="${UXPLAY_SOURCE_DIR}" \
  UXPLAY_COMMIT="${UXPLAY_COMMIT}" \
  SKIP_INSTALL=NO

ditto "${ARCHIVE_PATH}/Products/Applications/StudyCast.app" "${APP_PATH}"

TARGET_BUILD_DIR="${EXPORT_DIR}" \
FULL_PRODUCT_NAME="StudyCast.app" \
UXPLAY_SOURCE_DIR="${UXPLAY_SOURCE_DIR}" \
UXPLAY_COMMIT="${UXPLAY_COMMIT}" \
PATCH_APP_EXECUTABLES=1 \
SIGN_APP_BUNDLE=0 \
  bash "${SCRIPT_DIR}/bundle_runtime.sh"

if [[ "${SIGNING_MODE}" == "developer-id" ]]; then
  codesign --force --timestamp --options runtime --deep --sign "${DEVELOPER_ID_APPLICATION}" "${APP_PATH}"
else
  codesign --force --timestamp=none --options runtime --deep --sign - "${APP_PATH}"
fi
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

cp -R "${APP_PATH}" "${STAGING_DIR}/StudyCast.app"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "StudyCast ${RELEASE_VERSION}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

if [[ "${SIGNING_MODE}" == "developer-id" ]]; then
  codesign --force --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${DMG_PATH}"
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARYTOOL_PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
  spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"
else
  echo "Created an unsigned, unnotarized preview DMG. macOS Gatekeeper will require manual user approval."
fi

git archive --format=tar.gz --prefix="StudyCast-${RELEASE_VERSION}/" HEAD > "${SOURCE_TARBALL}"
if git -C "${UXPLAY_SOURCE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${UXPLAY_SOURCE_DIR}" archive \
    --format=tar.gz \
    --prefix="UxPlay-${UXPLAY_COMMIT}/" \
    "${UXPLAY_COMMIT}" > "${UXPLAY_TARBALL}"
else
  tar -C "$(dirname "${UXPLAY_SOURCE_DIR}")" \
    --exclude='CMakeFiles' \
    --exclude='CMakeCache.txt' \
    --exclude='cmake_install.cmake' \
    --exclude='Makefile' \
    -czf "${UXPLAY_TARBALL}" \
    "$(basename "${UXPLAY_SOURCE_DIR}")"
fi
cp Resources/ThirdPartyNotices/ThirdPartyNotices.md "${ASSETS_DIR}/ThirdPartyNotices.md"
cp Resources/ThirdPartyNotices/SourceOffer.md "${ASSETS_DIR}/SourceOffer.md"

popd >/dev/null

cat <<EOF
Release assets are ready:
${DMG_PATH}
${SOURCE_TARBALL}
${UXPLAY_TARBALL}
${ASSETS_DIR}/ThirdPartyNotices.md
${ASSETS_DIR}/SourceOffer.md
Signing mode: ${SIGNING_MODE}
EOF

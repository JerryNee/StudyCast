#!/usr/bin/env bash
set -euo pipefail

missing=0

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing command: ${cmd}" >&2
    missing=1
  fi
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -e "${path}" ]]; then
    echo "missing ${label}: ${path}" >&2
    missing=1
  fi
}

require_executable() {
  local path="$1"
  local label="$2"
  if [[ ! -x "${path}" ]]; then
    echo "missing executable ${label}: ${path}" >&2
    missing=1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing environment variable: ${name}" >&2
    missing=1
  fi
}

SIGNING_MODE="${SIGNING_MODE:-developer-id}"

require_cmd xcodebuild
require_cmd xcrun
require_cmd brew
require_cmd hdiutil
require_cmd ditto

BREW_PREFIX="$(brew --prefix)"
GST_PREFIX="$(brew --prefix gstreamer 2>/dev/null || true)"
FFMPEG_PREFIX="$(brew --prefix ffmpeg 2>/dev/null || true)"

require_file "${GST_PREFIX}/bin/gst-inspect-1.0" "GStreamer gst-inspect"
require_file "${GST_PREFIX}/libexec/gstreamer-1.0/gst-plugin-scanner" "GStreamer plugin scanner"
require_executable "${FFMPEG_PREFIX}/bin/ffmpeg" "ffmpeg"
require_executable "${FFMPEG_PREFIX}/bin/ffprobe" "ffprobe"

require_env RELEASE_VERSION
require_env UXPLAY_SOURCE_DIR
require_env UXPLAY_COMMIT

case "${SIGNING_MODE}" in
  developer-id)
    require_env DEVELOPER_ID_APPLICATION
    require_env NOTARYTOOL_PROFILE
    if ! xcrun --find notarytool >/dev/null 2>&1; then
      echo "missing xcrun notarytool" >&2
      missing=1
    fi
    ;;
  adhoc)
    ;;
  *)
    echo "invalid SIGNING_MODE: ${SIGNING_MODE}; use developer-id or adhoc" >&2
    missing=1
    ;;
esac

if [[ -n "${UXPLAY_SOURCE_DIR:-}" ]]; then
  require_executable "${UXPLAY_SOURCE_DIR}/uxplay" "UxPlay helper"
  require_file "${UXPLAY_SOURCE_DIR}/LICENSE" "UxPlay license"
fi

if [[ "${missing}" -ne 0 ]]; then
  echo "Release dependency check failed." >&2
  exit 1
fi

cat <<EOF
Release dependency check passed.
Homebrew: ${BREW_PREFIX}
GStreamer: ${GST_PREFIX}
FFmpeg: ${FFMPEG_PREFIX}
UxPlay: ${UXPLAY_SOURCE_DIR} (${UXPLAY_COMMIT})
Signing mode: ${SIGNING_MODE}
EOF

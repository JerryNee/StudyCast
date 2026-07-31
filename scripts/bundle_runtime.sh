#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
GST_ROOT="${CONTENTS_DIR}/Frameworks/GStreamer"
GST_LIB_DIR="${GST_ROOT}/lib"
GST_PLUGIN_DIR="${GST_ROOT}/plugins"
NOTICE_DIR="${CONTENTS_DIR}/Resources/ThirdPartyNotices"

BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix 2>/dev/null || true)}"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
GST_PREFIX="${GST_PREFIX:-$(brew --prefix gstreamer 2>/dev/null || true)}"
GST_PREFIX="${GST_PREFIX:-${BREW_PREFIX}/opt/gstreamer}"
GLIB_PREFIX="${GLIB_PREFIX:-$(brew --prefix glib 2>/dev/null || true)}"
GLIB_PREFIX="${GLIB_PREFIX:-${BREW_PREFIX}/opt/glib}"
FFMPEG_PREFIX="${FFMPEG_PREFIX:-$(brew --prefix ffmpeg 2>/dev/null || true)}"
FFMPEG_PREFIX="${FFMPEG_PREFIX:-${BREW_PREFIX}/opt/ffmpeg}"

UXPLAY_SOURCE_DIR="${UXPLAY_SOURCE_DIR:-}"
UXPLAY_PATH="${UXPLAY_PATH:-}"
FFMPEG_PATH="${FFMPEG_PATH:-${FFMPEG_PREFIX}/bin/ffmpeg}"
FFPROBE_PATH="${FFPROBE_PATH:-${FFMPEG_PREFIX}/bin/ffprobe}"
GST_INSPECT="${GST_INSPECT:-${GST_PREFIX}/bin/gst-inspect-1.0}"
GST_PLUGIN_SCANNER_SRC="${GST_PLUGIN_SCANNER_SRC:-${GST_PREFIX}/libexec/gstreamer-1.0/gst-plugin-scanner}"
PATCH_APP_EXECUTABLES="${PATCH_APP_EXECUTABLES:-1}"
SIGN_APP_BUNDLE="${SIGN_APP_BUNDLE:-0}"
UXPLAY_COMMIT="${UXPLAY_COMMIT:-}"

if [[ -z "${UXPLAY_SOURCE_DIR}" ]]; then
  REPO_ROOT="${PROJECT_DIR:-$(pwd)}"
  # The vendored tree is the one StudyCast is built and tested against, so it
  # wins over a sibling checkout that may be an unpatched or stale UxPlay.
  VENDORED_UXPLAY_DIR="${REPO_ROOT}/third_party/UxPlay"
  SIBLING_UXPLAY_DIR="$(cd "${REPO_ROOT}/.." 2>/dev/null && pwd)/UxPlay"
  for candidate in "${VENDORED_UXPLAY_DIR}" "${SIBLING_UXPLAY_DIR}"; do
    if [[ -x "${candidate}/uxplay" ]]; then
      UXPLAY_SOURCE_DIR="${candidate}"
      break
    fi
  done
fi

if [[ -z "${UXPLAY_PATH}" && -n "${UXPLAY_SOURCE_DIR}" && -x "${UXPLAY_SOURCE_DIR}/uxplay" ]]; then
  UXPLAY_PATH="${UXPLAY_SOURCE_DIR}/uxplay"
fi
if [[ -z "${UXPLAY_PATH}" && -x "${BREW_PREFIX}/bin/uxplay" ]]; then
  UXPLAY_PATH="${BREW_PREFIX}/bin/uxplay"
fi

rm -rf "${GST_ROOT}/libexec"
mkdir -p "${HELPERS_DIR}" "${GST_LIB_DIR}" "${GST_PLUGIN_DIR}" "${NOTICE_DIR}"

copy_file() {
  local src="$1"
  local dst="$2"
  if [[ -f "${src}" ]]; then
    cp -L "${src}" "${dst}"
    chmod u+w "${dst}" || true
  fi
}

copy_helper() {
  local src="$1"
  local dst_name="$2"
  local label="$3"
  if [[ -z "${src}" ]]; then
    echo "warning: ${label} helper path is not configured" >&2
    return 0
  fi
  if [[ -x "${src}" ]]; then
    copy_file "${src}" "${HELPERS_DIR}/${dst_name}"
    chmod 755 "${HELPERS_DIR}/${dst_name}"
  else
    echo "warning: ${label} helper not found at ${src}" >&2
  fi
}

copy_helper "${UXPLAY_PATH}" "uxplay" "uxplay"
copy_helper "${FFMPEG_PATH}" "ffmpeg" "ffmpeg"
copy_helper "${FFPROBE_PATH}" "ffprobe" "ffprobe"

if [[ -n "${UXPLAY_SOURCE_DIR}" ]]; then
  copy_file "${UXPLAY_SOURCE_DIR}/LICENSE" "${NOTICE_DIR}/UxPlay-GPLv3.txt"
  copy_file "${UXPLAY_SOURCE_DIR}/README.md" "${NOTICE_DIR}/UxPlay-README.md"
elif [[ -n "${UXPLAY_PATH}" ]]; then
  UXPLAY_ROOT="$(cd "$(dirname "${UXPLAY_PATH}")/.." 2>/dev/null && pwd || true)"
  copy_file "${UXPLAY_ROOT}/LICENSE" "${NOTICE_DIR}/UxPlay-GPLv3.txt"
  copy_file "${UXPLAY_ROOT}/README.md" "${NOTICE_DIR}/UxPlay-README.md"
fi

copy_file "${GST_PREFIX}/LICENSE" "${NOTICE_DIR}/GStreamer-LICENSE.txt"
copy_file "${GLIB_PREFIX}/LGPL-2.1-or-later.txt" "${NOTICE_DIR}/GLib-LGPL-2.1-or-later.txt"
copy_file "${FFMPEG_PREFIX}/LICENSE.md" "${NOTICE_DIR}/FFmpeg-LICENSE.md"

{
  echo "StudyCast release runtime"
  echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "UxPlay path: ${UXPLAY_PATH:-not bundled}"
  echo "UxPlay commit: ${UXPLAY_COMMIT:-unknown}"
  echo "GStreamer prefix: ${GST_PREFIX}"
  echo "FFmpeg prefix: ${FFMPEG_PREFIX}"
} > "${NOTICE_DIR}/RuntimeVersions.txt"

is_homebrew_dep() {
  case "$1" in
    "${BREW_PREFIX}"/*|/opt/homebrew/*|/usr/local/*) return 0 ;;
    *) return 1 ;;
  esac
}

copy_deps_for() {
  local binary="$1"
  [[ -f "${binary}" ]] || return 0
  while IFS= read -r dep; do
    [[ -n "${dep}" ]] || continue
    is_homebrew_dep "${dep}" || continue
    local base
    base="$(basename "${dep}")"
    local dst="${GST_LIB_DIR}/${base}"
    if [[ ! -f "${dst}" && -f "${dep}" ]]; then
      copy_file "${dep}" "${dst}"
      copy_deps_for "${dst}"
    fi
  done < <(otool -L "${binary}" 2>/dev/null | awk 'NR > 1 {print $1}')
}

plugin_path_for_element() {
  "${GST_INSPECT}" "$1" 2>/dev/null | sed -n 's/^[[:space:]]*Filename[[:space:]]*//p' | tail -n 1
}

if [[ -x "${GST_INSPECT}" ]]; then
  for element in \
    udpsrc rtpjitterbuffer rtph264depay h264parse vtdec videoconvert appsink \
    rtpL16depay audioconvert audioresample volume osxaudiosink \
    avdec_h264 decodebin autovideosink autoaudiosink \
    queue filesink mp4mux aacparse
  do
    plugin_path="$(plugin_path_for_element "${element}")"
    if [[ -n "${plugin_path}" && -f "${plugin_path}" ]]; then
      plugin_dst="${GST_PLUGIN_DIR}/$(basename "${plugin_path}")"
      copy_file "${plugin_path}" "${plugin_dst}"
      copy_deps_for "${plugin_dst}"
    else
      echo "warning: GStreamer plugin for ${element} was not found" >&2
    fi
  done
else
  echo "warning: gst-inspect-1.0 not found; bundled GStreamer plugins were not copied" >&2
fi

if [[ -x "${GST_PLUGIN_SCANNER_SRC}" ]]; then
  copy_file "${GST_PLUGIN_SCANNER_SRC}" "${HELPERS_DIR}/gst-plugin-scanner"
  chmod 755 "${HELPERS_DIR}/gst-plugin-scanner"
  copy_deps_for "${HELPERS_DIR}/gst-plugin-scanner"
else
  echo "warning: gst-plugin-scanner not found at ${GST_PLUGIN_SCANNER_SRC}" >&2
fi

for helper in uxplay ffmpeg ffprobe; do
  copy_deps_for "${HELPERS_DIR}/${helper}"
done

if [[ "${PATCH_APP_EXECUTABLES}" == "1" ]]; then
  find "${MACOS_DIR}" -type f -print0 | while IFS= read -r -d '' binary; do
    copy_deps_for "${binary}"
  done
fi

patch_binary() {
  local binary="$1"
  [[ -f "${binary}" ]] || return 0
  file "${binary}" | grep -q "Mach-O" || return 0
  chmod u+w "${binary}" || true

  install_name_tool -add_rpath "@executable_path/../Frameworks/GStreamer/lib" "${binary}" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path" "${binary}" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path/../Frameworks/GStreamer/lib" "${binary}" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path/../lib" "${binary}" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path/../../lib" "${binary}" 2>/dev/null || true

  while IFS= read -r dep; do
    [[ -n "${dep}" ]] || continue
    is_homebrew_dep "${dep}" || continue
    base="$(basename "${dep}")"
    if [[ -f "${GST_LIB_DIR}/${base}" ]]; then
      install_name_tool -change "${dep}" "@rpath/${base}" "${binary}" 2>/dev/null || true
    fi
  done < <(otool -L "${binary}" 2>/dev/null | awk 'NR > 1 {print $1}')

  case "${binary}" in
    "${GST_LIB_DIR}"/*.dylib)
      install_name_tool -id "@rpath/$(basename "${binary}")" "${binary}" 2>/dev/null || true
      ;;
  esac
}

if [[ "${PATCH_APP_EXECUTABLES}" == "1" ]]; then
  find "${HELPERS_DIR}" "${GST_LIB_DIR}" "${GST_PLUGIN_DIR}" "${MACOS_DIR}" -type f -print0 | while IFS= read -r -d '' binary; do
    patch_binary "${binary}"
  done
else
  find "${HELPERS_DIR}" "${GST_LIB_DIR}" "${GST_PLUGIN_DIR}" -type f -print0 | while IFS= read -r -d '' binary; do
    patch_binary "${binary}"
  done
fi

find "${HELPERS_DIR}" "${GST_LIB_DIR}" "${GST_PLUGIN_DIR}" -type f -print0 | while IFS= read -r -d '' binary; do
  if file "${binary}" | grep -q "Mach-O"; then
    codesign --force --sign - --timestamp=none "${binary}" >/dev/null 2>&1 || true
  fi
done

if [[ "${PATCH_APP_EXECUTABLES}" == "1" && "${SIGN_APP_BUNDLE}" == "1" ]]; then
  codesign --force --sign - --timestamp=none --deep "${APP_DIR}" >/dev/null 2>&1 || true
fi

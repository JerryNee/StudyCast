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

UXPLAY_PATH="${UXPLAY_PATH:-${HOME}/Desktop/Vision Pro/LPVT/UxPlay/uxplay}"
UXPLAY_ROOT="$(cd "$(dirname "${UXPLAY_PATH}")" 2>/dev/null && pwd || true)"
GST_INSPECT="${GST_INSPECT:-/opt/homebrew/bin/gst-inspect-1.0}"
GST_PLUGIN_SCANNER_SRC="${GST_PLUGIN_SCANNER_SRC:-/opt/homebrew/opt/gstreamer/libexec/gstreamer-1.0/gst-plugin-scanner}"
PATCH_APP_EXECUTABLES="${PATCH_APP_EXECUTABLES:-1}"
SIGN_APP_BUNDLE="${SIGN_APP_BUNDLE:-0}"

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

if [[ -x "${UXPLAY_PATH}" ]]; then
  copy_file "${UXPLAY_PATH}" "${HELPERS_DIR}/uxplay"
  chmod 755 "${HELPERS_DIR}/uxplay"
else
  echo "warning: uxplay helper not found at ${UXPLAY_PATH}; Debug builds can still use AppModel.uxplayPath fallback" >&2
fi

if [[ -n "${UXPLAY_ROOT}" ]]; then
  copy_file "${UXPLAY_ROOT}/LICENSE" "${NOTICE_DIR}/UxPlay-GPLv3.txt"
  copy_file "${UXPLAY_ROOT}/README.md" "${NOTICE_DIR}/UxPlay-README.md"
fi

copy_file "/opt/homebrew/opt/gstreamer/LICENSE" "${NOTICE_DIR}/GStreamer-LICENSE.txt"
copy_file "/opt/homebrew/opt/glib/LGPL-2.1-or-later.txt" "${NOTICE_DIR}/GLib-LGPL-2.1-or-later.txt"

is_homebrew_dep() {
  case "$1" in
    /opt/homebrew/*|/usr/local/*) return 0 ;;
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
    if [[ ! -f "${dst}" ]]; then
      if [[ -f "${dep}" ]]; then
        copy_file "${dep}" "${dst}"
        copy_deps_for "${dst}"
      fi
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

if [[ -f "${HELPERS_DIR}/uxplay" ]]; then
  copy_deps_for "${HELPERS_DIR}/uxplay"
fi

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

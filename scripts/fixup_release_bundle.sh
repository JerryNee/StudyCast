#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /path/to/StudyCast.app" >&2
  echo "required for release: UXPLAY_SOURCE_DIR, UXPLAY_COMMIT" >&2
  exit 64
fi

APP_DIR="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [[ ! -d "${APP_DIR}/Contents" ]]; then
  echo "error: not a macOS app bundle: ${APP_DIR}" >&2
  exit 66
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TARGET_BUILD_DIR="$(dirname "${APP_DIR}")"
export FULL_PRODUCT_NAME="$(basename "${APP_DIR}")"
export PATCH_APP_EXECUTABLES=1
export SIGN_APP_BUNDLE=1

bash "${SCRIPT_DIR}/bundle_runtime.sh"

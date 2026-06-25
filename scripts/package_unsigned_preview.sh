#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SIGNING_MODE=adhoc "${SCRIPT_DIR}/package_release.sh"

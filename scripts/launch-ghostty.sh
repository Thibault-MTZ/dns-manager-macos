#!/bin/bash
set -euo pipefail
LAUNCH_DIR="$(cd "$(dirname "$0")" && pwd)"
# Copied into dist by build.sh; the executable is next to this launcher.
exec /usr/bin/open -na Ghostty.app --args -e "$LAUNCH_DIR/dns-manager" --tui

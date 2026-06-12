#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Unsupported platform: delses currently targets macOS."
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift toolchain not found. Install Xcode Command Line Tools or Swift first."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="$HOME/.local/bin"

swift build -c release --package-path "$PROJECT_DIR"
BIN_DIR="$(swift build -c release --package-path "$PROJECT_DIR" --show-bin-path)"

mkdir -p "$INSTALL_DIR"
install -m 755 "$BIN_DIR/delses" "$INSTALL_DIR/delses"

echo "Installed: $INSTALL_DIR/delses"

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    ;;
  *)
    echo "Note: $INSTALL_DIR is not in PATH."
    echo "Add it manually if you want to run delses without a full path."
    ;;
esac

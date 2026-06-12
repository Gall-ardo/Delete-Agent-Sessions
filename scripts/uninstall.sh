#!/usr/bin/env bash

set -euo pipefail

TARGET="$HOME/.local/bin/delses"

if [ -f "$TARGET" ]; then
  rm -f "$TARGET"
  echo "Removed: $TARGET"
else
  echo "Not installed: $TARGET"
fi

echo "Archive preserved: $HOME/.delses"

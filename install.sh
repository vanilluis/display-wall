#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: 'swift' not found. Install Xcode Command Line Tools first:"
  echo "  xcode-select --install"
  exit 1
fi

if [ -w /usr/local/bin ]; then
  TARGET_DIR=/usr/local/bin
else
  TARGET_DIR="$HOME/.local/bin"
  mkdir -p "$TARGET_DIR"
fi

chmod +x "$SCRIPT_DIR/run.sh" "$SCRIPT_DIR/display-wall.swift"
ln -sf "$SCRIPT_DIR/run.sh" "$TARGET_DIR/display-wall"
echo "installed: $TARGET_DIR/display-wall -> $SCRIPT_DIR/run.sh"

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *)
    echo
    echo "note: $TARGET_DIR is not in your PATH."
    echo "add this line to ~/.zshrc (or your shell rc):"
    echo "  export PATH=\"$TARGET_DIR:\$PATH\""
    ;;
esac

echo
echo "done. run:  display-wall"

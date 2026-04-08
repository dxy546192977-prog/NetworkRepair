#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_EXE="$PROJECT_DIR/Win双击运行.exe"
LAUNCHER_DIR="$PROJECT_DIR/tools/win-launcher"

echo "[build] Building Windows launcher EXE..."
echo "[build] Output: $OUT_EXE"

(
  cd "$LAUNCHER_DIR"
  GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$OUT_EXE" .
)

echo "[build] Done."

#!/usr/bin/env sh
# Universal launcher: macOS / Linux / Git Bash on Windows
# Requires PowerShell 7+ (pwsh) on Unix. On Windows, prefers Windows PowerShell if pwsh is missing.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PS1_FILE="$SCRIPT_DIR/cursor-model-network-repair.ps1"

if [ ! -f "$PS1_FILE" ]; then
  echo "ERROR: Script not found: $PS1_FILE" >&2
  exit 1
fi

UNAME_S=$(uname -s 2>/dev/null || echo "")

case "$UNAME_S" in
  Darwin|Linux)
    if command -v pwsh >/dev/null 2>&1; then
      exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$PS1_FILE" "$@"
    fi
    echo "Install PowerShell 7 (pwsh): https://aka.ms/powershell" >&2
    exit 1
    ;;
  MINGW*|MSYS*|CYGWIN*)
    if command -v pwsh >/dev/null 2>&1; then
      exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$PS1_FILE" "$@"
    fi
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1_FILE" "$@"
    ;;
  *)
    if command -v pwsh >/dev/null 2>&1; then
      exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$PS1_FILE" "$@"
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1_FILE" "$@"
      exit $?
    fi
    echo "PowerShell not found. Install pwsh or use Windows PowerShell." >&2
    exit 1
    ;;
esac

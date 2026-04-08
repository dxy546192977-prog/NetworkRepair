#!/bin/zsh
# ============================================================================
#  install.sh — Cursor Network Repair 安装器
#  将工具安装到 ~/.local/share/cursor-network-repair/<version>
#  并在 ~/.local/bin/ 创建 cursor-network-repair 符号链接
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(tr -d '\n' < "$SCRIPT_DIR/src/VERSION" 2>/dev/null || echo "unknown")

INSTALL_BASE="${CURSOR_REPAIR_INSTALL_BASE:-$HOME/.local/share/cursor-network-repair}"
BIN_DIR="${CURSOR_REPAIR_BIN_DIR:-$HOME/.local/bin}"
INSTALL_DIR="$INSTALL_BASE/$VERSION"

UPGRADE=false
for arg in "$@"; do
    case "$arg" in
        --upgrade) UPGRADE=true ;;
        --help|-h)
            echo "Usage: ./install.sh [--upgrade]"
            echo "  --upgrade   Overwrite existing installation"
            exit 0
            ;;
    esac
done

echo ""
echo "================================================================"
echo "  Cursor Network Repair — Installer"
echo "================================================================"
echo "  Version:     $VERSION"
echo "  Install to:  $INSTALL_DIR"
echo "  CLI link:    $BIN_DIR/cursor-network-repair"
echo ""

if [[ -d "$INSTALL_DIR" && "$UPGRADE" != true ]]; then
    echo "[INFO] v$VERSION is already installed at:"
    echo "       $INSTALL_DIR"
    echo ""
    echo "  Use --upgrade to overwrite."
    exit 0
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$BIN_DIR"

echo "[1/3] Copying files..."
rsync -a --delete \
    --exclude '.DS_Store' \
    --exclude '.git' \
    --exclude '.archive' \
    --exclude 'logs/*' \
    --exclude 'tools' \
    --exclude 'install.sh' \
    --exclude 'Win双击运行.exe' \
    "$SCRIPT_DIR/" "$INSTALL_DIR/"

echo "[2/3] Creating symlink..."
chmod +x "$INSTALL_DIR/src/bin/cursor-network-repair" 2>/dev/null || true
chmod +x "$INSTALL_DIR/src/lib/network_repair.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/src/lib/network_check.sh" 2>/dev/null || true
ln -sfn "$INSTALL_DIR/src/bin/cursor-network-repair" "$BIN_DIR/cursor-network-repair"
echo "  $BIN_DIR/cursor-network-repair → $INSTALL_DIR/src/bin/cursor-network-repair"

echo "[3/3] Checking PATH..."
if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo "  $BIN_DIR is already in PATH"
else
    echo ""
    echo "  [ACTION REQUIRED] Add this to your ~/.zshrc:"
    echo ""
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
    echo "  Then run: source ~/.zshrc"
fi

echo ""
echo "================================================================"
echo "  Installation complete!"
echo "================================================================"
echo ""
echo "  Usage:"
echo "    cursor-network-repair              # Run repair"
echo "    cursor-network-repair --help       # Show options"
echo ""

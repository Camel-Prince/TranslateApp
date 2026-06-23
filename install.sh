#!/bin/bash
# ============================================================
# TranslateApp — One-command installer for macOS (M1/M2/M3/M4)
# ============================================================
# Quick start:
#   git clone <repo-url> translate && cd translate && bash install.sh
#
# What this does:
#   1. Checks Swift / Xcode CLT
#   2. Installs pymupdf (tries system python3 first, then miniforge)
#   3. Builds the app
#   4. Opens it for you
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$PROJECT_DIR/build/TranslateApp.app"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   TranslateApp — 划词翻译安装器     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""

# ---- Step 1: Check prerequisites ----
echo -e "${YELLOW}[1/4]${NC} Checking prerequisites..."

# Check Swift / Xcode CLT
if ! command -v swiftc &> /dev/null; then
    echo -e "${RED}✗ swiftc not found. Install Xcode Command Line Tools:${NC}"
    echo "    xcode-select --install"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} swiftc $(swiftc --version | head -1)"

# Check macOS version
OS_VER=$(sw_vers -productVersion | cut -d. -f1)
if [ "$OS_VER" -lt 13 ]; then
    echo -e "${RED}✗ macOS 13.0+ required (found: $(sw_vers -productVersion))${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} macOS $(sw_vers -productVersion)"

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    echo -e "  ${GREEN}✓${NC} Apple Silicon ($ARCH) — M4 optimized"
elif [ "$ARCH" = "x86_64" ]; then
    echo -e "  ${GREEN}✓${NC} Intel ($ARCH)"
else
    echo -e "  ${YELLOW}⚠${NC} Unknown architecture: $ARCH"
fi

# ---- Step 2: Set up Python with pymupdf ----
echo ""
echo -e "${YELLOW}[2/4]${NC} Setting up Python with pymupdf..."

PYTHON_BIN=""

# Try existing Python environments first
for candidate in \
    "python3" \
    "$HOME/miniconda3/envs/paper_agent/bin/python3" \
    "$HOME/anaconda3/envs/paper_agent/bin/python3" \
    "$HOME/miniforge3/envs/paper_agent/bin/python3" \
    "/opt/homebrew/bin/python3" \
    "/usr/local/bin/python3" \
    "/usr/bin/python3"
do
    if [ -x "$candidate" ] || command -v "$candidate" &>/dev/null; then
        PY=$(command -v "$candidate" 2>/dev/null || echo "$candidate")
        if $PY -c "import pymupdf; print('OK')" &>/dev/null; then
            PYTHON_BIN="$PY"
            echo -e "  ${GREEN}✓${NC} Found Python with pymupdf: $PYTHON_BIN"
            break
        fi
    fi
done

# If no working Python found, set one up
if [ -z "$PYTHON_BIN" ]; then
    echo -e "  ${YELLOW}⚠ No Python with pymupdf found. Setting one up...${NC}"
    
    # Try system python3 first
    if command -v python3 &>/dev/null; then
        PYTHON_BIN="$(command -v python3)"
        echo "  Installing pymupdf via pip..."
        $PYTHON_BIN -m pip install --user pymupdf 2>/dev/null || {
            # pip install --user might fail, try with --break-system-packages on new macOS
            $PYTHON_BIN -m pip install --break-system-packages pymupdf 2>/dev/null || true
        }
        if $PYTHON_BIN -c "import pymupdf" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} pymupdf installed for $PYTHON_BIN"
        fi
    fi
    
    # If still no luck, create a venv
    if [ -z "$PYTHON_BIN" ] || ! $PYTHON_BIN -c "import pymupdf" &>/dev/null; then
        echo "  Creating local venv with pymupdf..."
        PYTHON_BIN="${PROJECT_DIR}/.venv/bin/python3"
        python3 -m venv "${PROJECT_DIR}/.venv"
        "${PROJECT_DIR}/.venv/bin/pip" install --quiet pymupdf
        echo -e "  ${GREEN}✓${NC} Created local venv: $PYTHON_BIN"
    fi
fi

# ---- Step 3: Build the app ----
echo ""
echo -e "${YELLOW}[3/4]${NC} Building TranslateApp..."

chmod +x "$PROJECT_DIR/build.sh"
bash "$PROJECT_DIR/build.sh"

echo -e "  ${GREEN}✓${NC} Build complete"

# ---- Step 4: Launch ----
echo ""
echo -e "${YELLOW}[4/4]${NC} Launching TranslateApp..."
open "$APP_BUNDLE"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✅ Installation complete!         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo "  📌 Usage:"
echo "     1. Grant accessibility permission when prompted"
echo "        (System Settings → Privacy → Accessibility)"
echo "     2. Select text anywhere, press Option+D"
echo "     3. Translation appears in floating panel"
echo ""
echo "  🔧 Rebuild after code changes:"
echo "     bash $PROJECT_DIR/build.sh"
echo ""
echo "  📄 Import papers for contextual translation:"
echo "     Click menu bar icon → 「📄 导入论文...」"
echo ""

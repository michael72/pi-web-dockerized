#!/bin/bash

# Setup script to initialize the Pi Docker configuration
# Lets you choose extra tools, agents and plugins, then wires up completions,
# aliases and a global command. Safe to re-run.

set -e

# Source the shared config module (provides colors, logging, and config functions)
# Resolve symlinks so SCRIPT_DIR points to the real source directory
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/config-lib.sh"

# Define colors before use (config-lib.sh provides defaults via : "${VAR:=...}")
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_NAME="pi-web-dockerized"
TARGET_SCRIPT="$SCRIPT_DIR/$SCRIPT_NAME.sh"

echo -e "${BLUE}Pi Docker Setup${NC}"
echo "================================"
echo ""

# Function to create directory if it doesn't exist
ensure_dir() {
    if [ ! -d "$1" ]; then
        echo -e "${YELLOW}Creating directory: $1${NC}"
        mkdir -p "$1"
    else
        echo -e "${GREEN}✓${NC} Directory exists: $1"
    fi
}

# --------------------------------------------------------------------------
# 1. Tools, agents and plugins (written to the config file)
# --------------------------------------------------------------------------
interactive_config_setup

# --------------------------------------------------------------------------
# 2. State directories (after the config, which decides the agent directory)
# --------------------------------------------------------------------------
echo ""
echo "Checking directories..."
echo ""
load_config 2>/dev/null || true
ensure_dir "$(agent_dir)"
ensure_dir "$WEB_CONFIG_DIR"
ensure_dir "$WEB_DATA_DIR"
ensure_pi_dirs

# --------------------------------------------------------------------------
# Shell integration helpers
# --------------------------------------------------------------------------

# Append a marked block to a shell rc file unless the marker is already present
# Usage: add_rc_block <rc_file> <marker> <line...>
add_rc_block() {
    local rc_file="$1"
    local marker="$2"
    shift 2

    if grep -qF "$marker" "$rc_file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Already configured in $rc_file"
        return 0
    fi

    {
        echo ""
        echo "$marker"
        printf '%s\n' "$@"
    } >> "$rc_file"
    echo -e "${GREEN}✓${NC} Added to $rc_file"
    echo -e "${YELLOW}  Run: source $rc_file${NC}"
}

# Ask for which shells an integration should be installed, then call a function for each
# Usage: offer_shell_integration <label> <installer function taking "bash"|"zsh">
offer_shell_integration() {
    local label="$1"
    local installer="$2"

    echo "Would you like to set up $label?"
    echo "  1) bash"
    echo "  2) zsh"
    echo "  3) both"
    echo "  4) skip"
    local choice
    read -r -p "Select option (1-4): " choice

    case "$choice" in
        1) "$installer" bash ;;
        2) "$installer" zsh ;;
        3) "$installer" bash; "$installer" zsh ;;
        4) echo "Skipping $label." ;;
        *) echo -e "${YELLOW}Invalid choice, skipping $label.${NC}" ;;
    esac
}

install_completion() {
    local shell_name="$1"
    add_rc_block "$HOME/.${shell_name}rc" "# Pi Dockerized completion" \
        "[ -f \"$SCRIPT_DIR/completions/$shell_name.sh\" ] && source \"$SCRIPT_DIR/completions/$shell_name.sh\""
}

install_aliases() {
    local shell_name="$1"
    add_rc_block "$HOME/.${shell_name}rc" "# Pi Dockerized aliases" \
        "alias pid='$TARGET_SCRIPT'" \
        "alias pid-run='$TARGET_SCRIPT run'" \
        "alias pid-web='$TARGET_SCRIPT web'" \
        "alias pid-auth='$TARGET_SCRIPT auth'"
}

# --------------------------------------------------------------------------
# 3. Shell completions
# --------------------------------------------------------------------------
echo ""
echo -e "${BLUE}Shell Completions Setup${NC}"
if grep -qF "# Pi Dockerized completion" "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Shell completions already configured"
    read -r -p "Reconfigure completions? (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]] && offer_shell_integration "shell completions (tab completion for commands)" install_completion
else
    offer_shell_integration "shell completions (tab completion for commands)" install_completion
fi

# --------------------------------------------------------------------------
# 4. Shell aliases
# --------------------------------------------------------------------------
echo ""
echo -e "${BLUE}Shell Aliases Setup${NC}"
echo "Aliases: pid (wrapper), pid-run, pid-web, pid-auth"
if grep -qF "# Pi Dockerized aliases" "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Shell aliases already configured"
    read -r -p "Reconfigure aliases? (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]] && offer_shell_integration "shell aliases" install_aliases
else
    offer_shell_integration "shell aliases" install_aliases
fi

# --------------------------------------------------------------------------
# 5. Global install (symlink to PATH)
# --------------------------------------------------------------------------
echo ""
echo -e "${BLUE}Global Installation${NC}"

INSTALL_DIR="$HOME/.local/bin"

if [ -L "$INSTALL_DIR/$SCRIPT_NAME" ] && [ "$(readlink -f "$INSTALL_DIR/$SCRIPT_NAME")" = "$(readlink -f "$TARGET_SCRIPT")" ]; then
    echo -e "${GREEN}✓${NC} Already installed globally: $INSTALL_DIR/$SCRIPT_NAME"
else
    echo "Install '$SCRIPT_NAME' as a command available from any directory."
    echo "This creates a symlink in ~/.local/bin."
    read -r -p "Install globally? (y/n): " install_global

    if [[ "$install_global" =~ ^[Yy]$ ]]; then
        mkdir -p "$INSTALL_DIR"

        if [ -L "$INSTALL_DIR/$SCRIPT_NAME" ]; then
            ln -sf "$TARGET_SCRIPT" "$INSTALL_DIR/$SCRIPT_NAME"
            echo -e "${GREEN}✓${NC} Updated symlink: $INSTALL_DIR/$SCRIPT_NAME -> $TARGET_SCRIPT"
        elif [ -e "$INSTALL_DIR/$SCRIPT_NAME" ]; then
            echo -e "${YELLOW}⚠${NC} $INSTALL_DIR/$SCRIPT_NAME already exists and is not a symlink. Skipping."
        else
            ln -s "$TARGET_SCRIPT" "$INSTALL_DIR/$SCRIPT_NAME"
            echo -e "${GREEN}✓${NC} Created symlink: $INSTALL_DIR/$SCRIPT_NAME -> $TARGET_SCRIPT"
        fi
    else
        echo "Skipping global installation."
        echo "  You can always run it directly: $TARGET_SCRIPT"
    fi
fi

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    if [ -L "$INSTALL_DIR/$SCRIPT_NAME" ]; then
        echo -e "${YELLOW}⚠${NC} $INSTALL_DIR is not in your PATH. Add this to your shell rc file:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Build the Docker image:"
echo "     $SCRIPT_NAME build"
echo ""
echo "  2. Sign in to your LLM provider (no local Pi needed!):"
echo "     $SCRIPT_NAME auth"
echo "     (or pass an API key through an env.* entry; see '$SCRIPT_NAME config show')"
echo ""
echo "  3. Run Pi in your project, in the terminal or in the browser:"
echo "     $SCRIPT_NAME run /path/to/your/project"
echo "     $SCRIPT_NAME web /path/to/your/project"
echo ""
echo "Pi packages you selected are installed on first launch; the first start takes longer."
echo "Run setup.sh again at any time to change your choices."
echo ""

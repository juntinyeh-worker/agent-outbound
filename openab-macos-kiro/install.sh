#!/usr/bin/env bash
# install.sh — End-to-end setup for OpenAB + Kiro CLI agent on macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/openab-macos-kiro/openab-macos-kiro/install.sh | bash
set -euo pipefail

INSTALL_DIR="$HOME/openab-agent"
REPO_URL="https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/openab-macos-kiro/openab-macos-kiro"

echo "════════════════════════════════════════════════════════════"
echo " OpenAB + Kiro CLI Agent — macOS Setup"
echo "════════════════════════════════════════════════════════════"

###############################################################################
# Step 1: Install Homebrew (if missing)
###############################################################################
echo "==> [1/5] Checking Homebrew..."
if command -v brew &>/dev/null; then
  echo "    Homebrew installed ✓"
else
  echo "    Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add to PATH for this session
  if [ -f /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -f /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

###############################################################################
# Step 2: Install dependencies via Homebrew
###############################################################################
echo "==> [2/5] Installing dependencies..."
for pkg in rust gh git gettext; do
  if ! brew list "$pkg" &>/dev/null 2>&1; then
    brew install "$pkg"
  fi
done
echo "    Dependencies ready ✓"

###############################################################################
# Step 3: Install Kiro CLI
###############################################################################
echo "==> [3/5] Installing Kiro CLI..."
if command -v kiro-cli &>/dev/null; then
  echo "    Kiro CLI already installed ✓"
else
  curl -fsSL https://cli.kiro.dev/install | bash
  echo "    Kiro CLI installed ✓"
fi

###############################################################################
# Step 4: Build openab from source
###############################################################################
echo "==> [4/5] Building OpenAB..."
OPENAB_SRC="$HOME/.openab-src"
if [ ! -d "$OPENAB_SRC" ]; then
  git clone --depth 1 https://github.com/openabdev/openab.git "$OPENAB_SRC"
fi

if ! command -v openab &>/dev/null; then
  cd "$OPENAB_SRC"
  cargo build --release
  mkdir -p "$HOME/.local/bin"
  cp target/release/openab "$HOME/.local/bin/openab"
  # Ensure ~/.local/bin is in PATH
  if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc" 2>/dev/null || \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bash_profile"
    export PATH="$HOME/.local/bin:$PATH"
  fi
  echo "    OpenAB built ✓"
else
  echo "    OpenAB already installed ✓"
fi

###############################################################################
# Step 5: Download config files
###############################################################################
echo "==> [5/5] Setting up agent config..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

for f in config.toml .env.example start.sh stop.sh; do
  curl -fsSL "$REPO_URL/$f" -o "$f"
done
chmod +x start.sh stop.sh

if [ ! -f .env ]; then
  cp .env.example .env
fi

###############################################################################
# Done
###############################################################################
echo ""
echo "════════════════════════════════════════════════════════════"
echo " ✅  Installation complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo " Next steps:"
echo ""
echo "   1. Authenticate Kiro CLI:"
echo "      kiro-cli login"
echo ""
echo "   2. Configure the agent:"
echo "      cd $INSTALL_DIR"
echo "      vim .env"
echo ""
echo "   3. Start the agent:"
echo "      ./start.sh"
echo ""

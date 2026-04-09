#!/bin/bash
# Claude Pet Installer
# Builds the project and configures Claude Code: MCP server, hook, status line, and data files.
# Works for any user on any machine — no hardcoded paths.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PET_DATA_DIR="$HOME/.claude/pet-buddy"
SETTINGS_FILE="$HOME/.claude/settings.json"
SERVER_PATH="$SCRIPT_DIR/dist/server.js"
HOOK_PATH="$SCRIPT_DIR/scripts/pet-hook.sh"
STATUSLINE_PATH="$SCRIPT_DIR/scripts/pet-statusline.sh"

echo ""
echo "  ▄█▀██▀█▄"
echo "  ▀█▀█▀███   Claude Pet Installer"
echo "   ▄▄▄▄███"
echo "  ▀██████"
echo ""

# ── Prerequisites ─────────────────────────────────────────────────────────────
MISSING=""
command -v node &>/dev/null || MISSING="${MISSING}  - node (Node.js 20+)\n"
command -v jq &>/dev/null   || MISSING="${MISSING}  - jq (https://jqlang.github.io/jq/download/)\n"
if [ -n "$MISSING" ]; then
  echo "Missing required tools:"
  printf "$MISSING"
  echo ""
  echo "Install them and re-run this script."
  exit 1
fi

# ── Step 1: Install dependencies and build ────────────────────────────────────
echo "[1/5] Installing dependencies..."
cd "$SCRIPT_DIR"
npm install --silent 2>&1 | tail -1
echo "[2/5] Building..."
npm run build --silent 2>&1
echo "  Done."

# ── Step 2: Set up pet data directory ─────────────────────────────────────────
echo "[3/5] Setting up pet data..."
mkdir -p "$PET_DATA_DIR"

# Copy data files (sprites + creatures for statusline)
cp "$SCRIPT_DIR/src/data/sprites.json" "$PET_DATA_DIR/sprites.json"
cp "$SCRIPT_DIR/src/data/creatures.json" "$PET_DATA_DIR/creatures.json"

# Create default state if none exists — random family assignment
if [ ! -f "$PET_DATA_DIR/state.json" ]; then
  FAMILIES=$(jq -r '.[].family_id' "$SCRIPT_DIR/src/data/families.json")
  FAMILY_ARRAY=($FAMILIES)
  RANDOM_IDX=$((RANDOM % ${#FAMILY_ARRAY[@]}))
  RANDOM_FAMILY="${FAMILY_ARRAY[$RANDOM_IDX]}"
  FAMILY_NAME=$(jq -r ".[] | select(.family_id == \"$RANDOM_FAMILY\") | .stages[0].name" "$SCRIPT_DIR/src/data/families.json")

  cat > "$PET_DATA_DIR/state.json" << STATE
{
  "currentLineId": "$RANDOM_FAMILY",
  "currentStageIndex": 0,
  "xp": 0,
  "totalPromptsScored": 0,
  "streakDays": 0,
  "lastActiveDate": "",
  "milestonesCompleted": [],
  "evolutionHistory": []
}
STATE
  echo "  Assigned family: $RANDOM_FAMILY — Your pet is a $FAMILY_NAME!"
else
  echo "  Existing pet state preserved."
fi

# Create display config if none exists
if [ ! -f "$PET_DATA_DIR/config.json" ]; then
  echo '{"display": true}' > "$PET_DATA_DIR/config.json"
fi

# Install /pet skill globally
mkdir -p "$HOME/.claude/skills/pet"
if cp "$SCRIPT_DIR/skills/pet/SKILL.md" "$HOME/.claude/skills/pet/SKILL.md" 2>/dev/null; then
  echo "  /pet command installed."
else
  echo "  Warning: Could not install /pet command. Copy skills/pet/SKILL.md to ~/.claude/skills/pet/ manually."
fi
echo "  Data files ready."

# ── Step 3: Register MCP server ───────────────────────────────────────────────
echo "[4/5] Configuring Claude Code..."

if command -v claude &> /dev/null; then
  # Remove existing claude-pet server if present (idempotent reinstall)
  claude mcp remove claude-pet 2>/dev/null || true
  claude mcp add --transport stdio claude-pet -- node "$SERVER_PATH" 2>&1 && \
    echo "  MCP server registered." || \
    { echo "  Warning: Could not register MCP server. Run manually:"; \
      echo "    claude mcp add --transport stdio claude-pet -- node $SERVER_PATH"; }
else
  echo "  Warning: 'claude' CLI not found. Add the MCP server manually:"
  echo "    claude mcp add --transport stdio claude-pet -- node $SERVER_PATH"
fi

# ── Step 4: Add hook + status line to settings ────────────────────────────────
echo "[5/5] Setting up hook and status line..."
mkdir -p "$HOME/.claude"

if [ ! -f "$SETTINGS_FILE" ]; then
  cat > "$SETTINGS_FILE" << SETTINGS
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_PATH"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "$STATUSLINE_PATH",
    "padding": 1
  }
}
SETTINGS
  echo "  Created settings with hook and status line."
else
  # Merge hook and status line into existing settings using node
  node -e "
    const fs = require('fs');
    let settings;
    try {
      settings = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf-8'));
    } catch (e) {
      console.error('  Error: ~/.claude/settings.json is malformed. Please fix it manually.');
      process.exit(1);
    }

    // Add hook
    if (!settings.hooks) settings.hooks = {};
    if (!settings.hooks.UserPromptSubmit) settings.hooks.UserPromptSubmit = [];
    const hasHook = settings.hooks.UserPromptSubmit.some(
      h => h.hooks && h.hooks.some(hh => hh.command && hh.command.includes('pet-hook'))
    );
    if (!hasHook) {
      settings.hooks.UserPromptSubmit.push({
        matcher: '',
        hooks: [{ type: 'command', command: '$HOOK_PATH' }]
      });
    }

    // Set status line (only if not already customized)
    if (!settings.statusLine) {
      settings.statusLine = {
        type: 'command',
        command: '$STATUSLINE_PATH',
        padding: 1
      };
      console.log('  Status line configured.');
    } else {
      console.log('  Existing status line preserved. To use pet status line, set:');
      console.log('    \"statusLine\": { \"type\": \"command\", \"command\": \"$STATUSLINE_PATH\", \"padding\": 1 }');
    }

    fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(settings, null, 2));
    console.log('  Hook added.');
  "
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "  ═══════════════════════════════"
echo "  Installation complete!"
echo "  ═══════════════════════════════"
echo ""
echo "  Restart Claude Code, then try:"
echo "    • Type /pet status"
echo "    • Type /pet off to hide"
echo ""
echo "  Your creature is waiting!"
echo ""

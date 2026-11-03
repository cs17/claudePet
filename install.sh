#!/bin/bash
# Claude Pet Installer
# Builds the project and configures Claude Code: MCP server, hook, status line, and data files.
# Works for any user on any machine — no hardcoded paths.
#
# Runs on macOS, Linux, WSL and Windows. On Windows it must be started from Git
# Bash, which is what Claude Code itself uses to run this project's scripts.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PET_DATA_DIR="$HOME/.claude/claude-pet"
SETTINGS_FILE="$HOME/.claude/settings.json"
SERVER_PATH="$SCRIPT_DIR/dist/server.js"
HOOK_PATH="$SCRIPT_DIR/scripts/pet-hook.sh"
# Native Windows resolves a bare .sh command through the file association, which
# pops a "choose an app" dialog instead of running the hook. The .cmd launcher
# starts bash.exe itself and keeps stdin/stdout connected.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) HOOK_PATH="$SCRIPT_DIR/scripts/pet-hook.cmd" ;;
esac
STATUSLINE_PATH="$SCRIPT_DIR/scripts/pet-statusline.sh"

# ── Path handling ─────────────────────────────────────────────────────────────
# Two kinds of path are written into Claude Code's config. The shell keeps using
# the MSYS form Git Bash reports ($HOME is /c/Users/... there), but a path that
# goes into settings.json or the MCP registration is consumed by the native
# Windows build of Claude Code, which cannot resolve /c/... — and on a machine
# without Git Bash, statusLine commands are run by PowerShell, which cannot
# either. cygpath -m gives C:/Users/..., which Git Bash, PowerShell and Node all
# accept. On macOS/Linux cygpath does not exist and the path is already correct.
settings_path() { # $1 = path → the form to write into config files
  local p="${1:-}"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# ── Linking ───────────────────────────────────────────────────────────────────
# Symlinks are the point: the status line reads these files while the engine
# reads dist/data, and copies drift the moment either side is regenerated. But
# Windows refuses symlinks to a normal user without Developer Mode, so fall back
# to a directory junction (no elevation needed, directories only) and only then
# to a copy — which is what the caller is told about, because a copy will go
# stale and needs a reinstall to refresh.
COPIED=""
link_path() { # $1 = target, $2 = path to create
  local target="$1" dest="$2"
  if ln -sfn "$target" "$dest" 2>/dev/null; then
    return 0
  fi
  if [[ -d "$target" ]] && command -v cmd.exe >/dev/null 2>&1 \
     && command -v cygpath >/dev/null 2>&1; then
    local wt wd
    wt=$(cygpath -w "$target" 2>/dev/null) && wd=$(cygpath -w "$dest" 2>/dev/null) && \
      cmd.exe /c mklink /J "$wd" "$wt" >/dev/null 2>&1 && return 0
  fi
  rm -rf "$dest" 2>/dev/null || true
  if cp -R "$target" "$dest" 2>/dev/null; then
    COPIED="${COPIED}  ${dest}
"
    return 0
  fi
  return 1
}

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
  printf '%b' "$MISSING"
  echo ""
  echo "Install them and re-run this script."
  exit 1
fi

# Python is optional but carries the cost estimate and the output rate, and it
# is the one dependency Windows is most likely to have only as the Microsoft
# Store stub — which answers `command -v`, prints a complaint and exits 0. Ask
# it for a marker instead. The status line runs the same probe, so this check
# exists to warn early rather than to decide anything at runtime.
have_python() {
  local c
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 \
      && [[ "$("$c" -c 'import sys;sys.stdout.write("PETPY")' 2>/dev/null)" == "PETPY" ]] \
      && return 0
  done
  return 1
}
if ! have_python; then
  echo "  Note: no working Python 3 found — the status line will show cost from"
  echo "        Claude Code's own figure and will not show the output rate."
  echo "        (On Windows, the Microsoft Store python stub does not count.)"
fi
command -v curl &>/dev/null || echo "  Note: curl not found — price/FX refresh will be skipped."


# ── Step 1: Install dependencies and build ────────────────────────────────────
echo "[1/5] Installing dependencies..."
cd "$SCRIPT_DIR"
npm install --ignore-scripts --silent 2>&1 | tail -1
echo "[2/5] Building..."
npm run build --silent 2>&1
echo "  Done."

# ── Step 2: Set up pet data directory ─────────────────────────────────────────
echo "[3/5] Setting up pet data..."
mkdir -p "$PET_DATA_DIR"

# Link data files (sprites + creatures for statusline). Symlink rather than copy:
# the status line reads these while the engine reads dist/data, and copies drift
# the moment either side is regenerated. link_path falls back for Windows.
link_path "$SCRIPT_DIR/src/data/sprites.json" "$PET_DATA_DIR/sprites.json" \
  || echo "  Warning: could not link sprites.json"
link_path "$SCRIPT_DIR/src/data/creatures.json" "$PET_DATA_DIR/creatures.json" \
  || echo "  Warning: could not link creatures.json"

# Create default state if none exists — random family assignment
if [ ! -f "$PET_DATA_DIR/state.json" ]; then
  FAMILIES=$(jq -r '.[].family_id' "$SCRIPT_DIR/src/data/families.json")
  # read -a rather than ($FAMILIES): word splitting is what this relies on, but
  # saying so explicitly keeps it working under shellcheck-style strictness.
  read -r -a FAMILY_ARRAY <<< "$FAMILIES"
  RANDOM_IDX=$((RANDOM % ${#FAMILY_ARRAY[@]}))
  RANDOM_FAMILY="${FAMILY_ARRAY[$RANDOM_IDX]}"
  # --arg, not string interpolation: a family id with a quote in it would
  # otherwise end up inside the jq program.
  FAMILY_NAME=$(jq -r --arg id "$RANDOM_FAMILY" \
    '.[] | select(.family_id == $id) | .stages[0].name' \
    "$SCRIPT_DIR/src/data/families.json")

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

# Install /pet skill globally. Link the directory, not the file: the docs cover a
# <skill-name> entry being a symlink to a directory elsewhere, and this keeps the
# installed skill current with the checkout — a copied SKILL.md went stale and
# kept a destructive `echo > config.json` around after it was fixed here.
mkdir -p "$HOME/.claude/skills"
if [[ -e "$HOME/.claude/skills/pet" && ! -L "$HOME/.claude/skills/pet" ]]; then
  rm -rf "$HOME/.claude/skills/pet"   # an older install copied SKILL.md into a real dir
fi
if link_path "$SCRIPT_DIR/skills/pet" "$HOME/.claude/skills/pet"; then
  echo "  /pet command installed."
else
  echo "  Warning: Could not install /pet command. Copy skills/pet/ to ~/.claude/skills/pet/ manually."
fi
# Optional FX updater used by statusline (TTL-cached)
if [[ -f "$SCRIPT_DIR/scripts/update-fx-rate.sh" ]]; then
  link_path "$SCRIPT_DIR/scripts/update-fx-rate.sh" "$PET_DATA_DIR/update-fx-rate.sh"
fi
if [[ -f "$SCRIPT_DIR/scripts/update-model-pricing.sh" ]]; then
  link_path "$SCRIPT_DIR/scripts/update-model-pricing.sh" "$PET_DATA_DIR/update-model-pricing.sh"
fi
# The /pet skill calls this at a stable path, so it keeps working after a repo
# change without reinstalling the skill
if [[ -f "$SCRIPT_DIR/scripts/pet-toggle.sh" ]]; then
  link_path "$SCRIPT_DIR/scripts/pet-toggle.sh" "$PET_DATA_DIR/pet-toggle.sh"
fi

echo "  Data files ready."
if [ -n "$COPIED" ]; then
  echo ""
  echo "  Note: this system refused symlinks, so these were copied instead."
  echo "        They will not follow later repo changes; re-run ./install.sh"
  echo "        after updating the checkout or regenerating the data:"
  printf '%s' "$COPIED"
  echo ""
fi

# ── Step 3: Register MCP server ───────────────────────────────────────────────
echo "[4/5] Configuring Claude Code..."

if command -v claude &> /dev/null; then
  # Paths registered here are read by the native CLI, not by this shell, so
  # they go in the C:/... form (see settings_path).
  SERVER_CFG=$(settings_path "$SERVER_PATH")
  # Remove existing claude-pet server if present (idempotent reinstall)
  claude mcp remove claude-pet 2>/dev/null || true
  claude mcp add --transport stdio claude-pet -- node "$SERVER_CFG" 2>&1 && \
    echo "  MCP server registered." || \
    { echo "  Warning: Could not register MCP server. Run manually:"; \
      echo "    claude mcp add --transport stdio claude-pet -- node \"$SERVER_CFG\""; }
else
  echo "  Warning: 'claude' CLI not found. Add the MCP server manually:"
  echo "    claude mcp add --transport stdio claude-pet -- node \"$(settings_path "$SERVER_PATH")\""
fi

# ── Step 4: Add hook + status line to settings ────────────────────────────────
echo "[5/5] Setting up hook and status line..."
mkdir -p "$HOME/.claude"

# Config files are read by the native CLI, so paths go in C:/... form. The hook
# and statusLine entries are shell commands, but the shell that runs them is
# whichever Claude Code picked, so this form has to suit both.
HOOK_CFG=$(settings_path "$HOOK_PATH")
STATUSLINE_CFG=$(settings_path "$STATUSLINE_PATH")

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
            "command": "$HOOK_CFG"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "$STATUSLINE_CFG",
    "padding": 1
  }
}
SETTINGS
  echo "  Created settings with hook and status line."
else
  # Merge hook and status line into existing settings using node. Paths go
  # through the environment, never through this string: node -e expands it
  # first, and a Windows path loses every backslash on the way (\U, \a, \c, \s
  # are all escape sequences, so C:\Users\ada\.claude arrives as C:Usersada).
  PET_SETTINGS="$SETTINGS_FILE" PET_HOOK_CFG="$HOOK_CFG" \
  PET_STATUSLINE_CFG="$STATUSLINE_CFG" node -e '
    const fs = require("fs");
    const settingsFile = process.env.PET_SETTINGS;
    const hookCmd = process.env.PET_HOOK_CFG;
    const statusCmd = process.env.PET_STATUSLINE_CFG;

    let raw;
    try {
      raw = fs.readFileSync(settingsFile, "utf-8");
    } catch (e) {
      console.error("  Error: cannot read " + settingsFile + ": " + e.message);
      process.exit(1);
    }
    // A BOM is what a Windows editor leaves behind, and JSON.parse rejects it
    // outright, so strip it before parsing and keep it out of the rewrite too.
    if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);

    let settings;
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      console.error("  Error: ~/.claude/settings.json is malformed. Please fix it manually.");
      process.exit(1);
    }

    // Add hook
    if (!settings.hooks) settings.hooks = {};
    if (!settings.hooks.UserPromptSubmit) settings.hooks.UserPromptSubmit = [];
    // Replace an older hook path in place -- notably a bare .sh entry on
    // Windows -- instead of leaving it beside the new one.
    let hasHook = false;
    for (const group of settings.hooks.UserPromptSubmit) {
      if (!group.hooks) continue;
      for (const h of group.hooks) {
        if (typeof h.command === "string" && h.command.includes("pet-hook")) {
          h.command = hookCmd;
          hasHook = true;
        }
      }
    }
    if (!hasHook) {
      settings.hooks.UserPromptSubmit.push({
        matcher: "",
        hooks: [{ type: "command", command: hookCmd }]
      });
    }

    // Set status line (only if not already customized)
    if (!settings.statusLine) {
      settings.statusLine = {
        type: "command",
        command: statusCmd,
        padding: 1
      };
      console.log("  Status line configured.");
    } else {
      console.log("  Existing status line preserved. To use pet status line, set:");
      console.log("    \"statusLine\": { \"type\": \"command\", \"command\": \"" + statusCmd + "\", \"padding\": 1 }");
    }

    fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2));
    console.log("  Hook added.");
  '
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

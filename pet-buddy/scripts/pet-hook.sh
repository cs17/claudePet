#!/bin/bash
# pet-hook.sh — called by Claude Code on user-prompt-submit
# Reads the user's prompt from stdin, scores it, and awards XP directly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pipe stdin (the user's prompt) to the scoring script
cat | node "$SCRIPT_DIR/score-prompt.js" 2>/dev/null

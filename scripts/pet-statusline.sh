#!/bin/bash
# pet-statusline.sh — Pet Buddy status line for Claude Code
# This script is meant to be sourced/called from a main statusline script,
# or used standalone as the statusline command.
#
# Standalone usage (in ~/.claude/settings.json):
#   "statusLine": { "type": "command", "command": "/path/to/pet-statusline.sh" }
#
# It reads JSON from stdin (Claude Code status line protocol) and outputs
# a status bar with the pet creature displayed above it.

input=$(cat)

# ── Parse JSON ───────────────────────────────────────────────────────────────
MODEL=$(echo "$input"    | jq -r '.model.display_name // "Claude"')
DIR=$(echo "$input"      | jq -r '.workspace.current_dir // .cwd // ""')
PCT=$(echo "$input"      | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
COST=$(echo "$input"     | jq -r '.cost.total_cost_usd // 0')


# ── Dir: shorten to ~/parent/dir ─────────────────────────────────────────────
DIR="${DIR/#$HOME/~}"
NSEGS=$(echo "$DIR" | tr -cd '/' | wc -c | tr -d ' ')
if [ "$NSEGS" -gt 2 ]; then
  PARENT=$(echo "$DIR" | awk -F/ '{print $(NF-1)}')
  LEAF=$(echo "$DIR"   | awk -F/ '{print $NF}')
  DIR_DISPLAY="~/${PARENT}/${LEAF}"
else
  DIR_DISPLAY="$DIR"
fi

# ── Git branch ───────────────────────────────────────────────────────────────
GIT_DIR="${DIR/#\~/$HOME}"
BRANCH=$(git -C "$GIT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)

# ── Cost ─────────────────────────────────────────────────────────────────────
COST_FMT=$(printf '$%.4f' "$COST")

# ── Plan detection (removed — not relevant for most users) ───────────────────
PLAN=""

# ── Context bar (15 chars wide) ──────────────────────────────────────────────
[ -z "$PCT" ] && PCT=0
BAR_W=15
FILLED=$((PCT * BAR_W / 100))
[ "$FILLED" -gt "$BAR_W" ] && FILLED=$BAR_W
EMPTY=$((BAR_W - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && BAR=$(printf "%${FILLED}s" | tr ' ' '▓')
[ "$EMPTY"  -gt 0 ] && BAR="${BAR}$(printf "%${EMPTY}s" | tr ' ' '░')"
BAR_CLR="\033[38;5;245m"

# ── ANSI palette ─────────────────────────────────────────────────────────────
RST="\033[0m"
GRAY="\033[38;5;245m"
DIM="\033[38;5;238m"
SEP="${DIM} │ ${RST}"

# ── Assemble status bar ──────────────────────────────────────────────────────
L=""
[ -n "$PLAN" ] && L="${GRAY}${PLAN}${RST}${SEP}"
L="${L}${GRAY}⬡ ${MODEL}${RST}"
L="${L}${SEP}${GRAY}${DIR_DISPLAY}${RST}"
[ -n "$BRANCH" ] && L="${L}${SEP}${GRAY}⎇ ${BRANCH}${RST}"
L="${L}${SEP}${BAR_CLR}${BAR}${RST}${GRAY} ${PCT}%${RST}"
L="${L}${SEP}${GRAY}${COST_FMT}${RST}"

# ── Pet Buddy (monstapix block art) ──────────────────────────────────────────
PET_DIR="$HOME/.claude/claude-pet"
PET_STATE="$PET_DIR/state.json"
PET_SPRITES="$PET_DIR/sprites.json"
PET_CONFIG="$PET_DIR/config.json"
PET_ACTIVITY="$PET_DIR/last-activity.json"
PET_DISPLAY=$(jq -r 'if .display == false then "false" else "true" end' "$PET_CONFIG" 2>/dev/null)

if [ "$PET_DISPLAY" = "true" ] && [ -f "$PET_STATE" ] && [ -f "$PET_SPRITES" ] && command -v jq &>/dev/null; then
  PET_STAGE_IDX=$(jq -r '.currentStageIndex // 0' "$PET_STATE")
  PET_LINE_ID=$(jq -r '.currentLineId // "titan"' "$PET_STATE")
  PET_XP=$(jq -r '.xp // 0' "$PET_STATE")

  # Read XP thresholds from creatures.json (family-aware)
  PET_CREATURES="$PET_DIR/creatures.json"
  NEXT_IDX=$((PET_STAGE_IDX + 1))
  TOTAL_STAGES=$(jq -r ".evolutionLines.\"${PET_LINE_ID}\".stages | length" "$PET_CREATURES" 2>/dev/null)
  if [ -n "$TOTAL_STAGES" ] && [ "$NEXT_IDX" -lt "$TOTAL_STAGES" ]; then
    PET_XP_NEXT=$(jq -r ".evolutionLines.\"${PET_LINE_ID}\".stages[$NEXT_IDX].xpRequired" "$PET_CREATURES")
  else
    PET_XP_NEXT="MAX"
  fi

  PET_NAME=$(jq -r ".evolutionLines.\"${PET_LINE_ID}\".stages[$PET_STAGE_IDX].name" "$PET_CREATURES" 2>/dev/null)

  # Read last activity message (within 10 min)
  PET_MSG=""
  if [ -f "$PET_ACTIVITY" ]; then
    ACT_TS=$(jq -r '.timestamp // 0' "$PET_ACTIVITY")
    ACT_MSG=$(jq -r '.message // ""' "$PET_ACTIVITY")
    NOW_S=$(date +%s)
    ACT_S=$((ACT_TS / 1000))
    AGE=$((NOW_S - ACT_S))
    if [ "$AGE" -lt 600 ] 2>/dev/null; then
      PET_MSG="$ACT_MSG"
    fi
  fi

  # Read sprite lines and print with message on first, info on last
  if [ -f "$PET_SPRITES" ]; then
    SPRITE_LINES=()
    while IFS= read -r line; do
      SPRITE_LINES+=("$line")
    done < <(jq -r ".\"${PET_LINE_ID}\".\"${PET_STAGE_IDX}\"[]" "$PET_SPRITES" 2>/dev/null)

    SPRITE_W=0
    for sl in "${SPRITE_LINES[@]}"; do
      [ ${#sl} -gt "$SPRITE_W" ] && SPRITE_W=${#sl}
    done
    SPRITE_W=$((SPRITE_W + 1))

    LAST_IDX=$(( ${#SPRITE_LINES[@]} - 1 ))
    for (( i=0; i<${#SPRITE_LINES[@]}; i++ )); do
      PADDED=$(printf "%-${SPRITE_W}s" "${SPRITE_LINES[$i]}")
      if [ "$i" -eq 0 ] && [ -n "$PET_MSG" ]; then
        printf "%b\n" "${GRAY}${PADDED} ${PET_MSG}${RST}"
      elif [ "$i" -eq "$LAST_IDX" ]; then
        printf "%b\n" "${GRAY}${PADDED} Pet: ◆ ${PET_NAME:-???}  ♥ ${PET_XP}/${PET_XP_NEXT} XP${RST}"
      else
        printf "%b\n" "${GRAY}${PADDED}${RST}"
      fi
    done
  fi

  printf "%b\n" "$L"
fi

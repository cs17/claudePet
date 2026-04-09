---
name: pet
description: Toggle pet display on/off, check status, or reset. Usage - /pet on, /pet off, /pet status, /pet reset
user_invocable: true
---

# Pet Display Toggle

The user wants to control their pet buddy display. Parse their argument:

- **`/pet on`** or **`/pet`** (no args): Turn display ON
- **`/pet off`**: Turn display OFF  
- **`/pet status`**: Show current pet info
- **`/pet reset`**: Reset pet to stage 1 with a random new family

## Actions

### Turn ON
Run this command:
```bash
echo '{"display": true}' > ~/.claude/claude-pet/config.json
```
Then respond: "Pet display turned ON."

### Turn OFF
Run this command:
```bash
echo '{"display": false}' > ~/.claude/claude-pet/config.json
```
Then respond: "Pet display turned OFF."

### Status
Read `~/.claude/claude-pet/state.json` and report the pet's current stage, XP, streak, and milestones. Also mention whether display is currently on or off by reading `~/.claude/claude-pet/config.json`.

### Reset
Run this command to pick a random family and reset:
```bash
FAMILIES=(titan swarm golem invader crawler brute phantom aberrant raptor)
RANDOM_FAMILY=${FAMILIES[$((RANDOM % ${#FAMILIES[@]}))]}
STAGE_NAME=$(jq -r ".evolutionLines.\"$RANDOM_FAMILY\".stages[0].name" ~/.claude/claude-pet/creatures.json)
cat > ~/.claude/claude-pet/state.json << STATE
{"currentLineId":"$RANDOM_FAMILY","currentStageIndex":0,"xp":0,"totalPromptsScored":0,"streakDays":0,"lastActiveDate":"","milestonesCompleted":[],"evolutionHistory":[]}
STATE
rm -f ~/.claude/claude-pet/last-activity.json
echo "$RANDOM_FAMILY $STAGE_NAME"
```
Read the output to get the assigned family and stage name. Then respond: "Pet reset! You got a **[stage name]** from the **[family]** line. Start fresh!"

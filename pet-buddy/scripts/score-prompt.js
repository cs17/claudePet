#!/usr/bin/env node
// score-prompt.js — Called by pet-hook.sh to score the user's prompt directly.
// Reads prompt from stdin, scores it, awards XP, writes last-activity for statusline.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DIST_DIR = resolve(__dirname, "..", "dist");
const DATA_DIR = resolve(homedir(), ".claude", "pet-buddy");

// Read prompt from stdin
let prompt = "";
try {
  prompt = readFileSync("/dev/stdin", "utf-8").trim();
} catch {
  process.exit(0);
}
if (!prompt) process.exit(0);

// Dynamic imports from the built dist
async function main() {
  try {
    const { scorePrompt, xpForScore } = await import(resolve(DIST_DIR, "engine", "scorer.js"));
    const { awardXp, checkEvolution, checkMilestones } = await import(resolve(DIST_DIR, "engine", "evolution.js"));

    if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });

    const stateFile = resolve(DATA_DIR, "state.json");
    const activityFile = resolve(DATA_DIR, "last-activity.json");
    const creaturesFile = resolve(DIST_DIR, "data", "creatures.json");

    // Load state
    let state;
    if (existsSync(stateFile)) {
      state = JSON.parse(readFileSync(stateFile, "utf-8"));
    } else {
      state = {
        currentLineId: "default", currentStageIndex: 0, xp: 0,
        totalPromptsScored: 0, streakDays: 0, lastActiveDate: "",
        milestonesCompleted: [], evolutionHistory: [],
      };
    }

    // Score
    const score = scorePrompt(prompt);
    const totalScore = Object.values(score).reduce((a, b) => a + b, 0);
    const xp = xpForScore(totalScore);
    awardXp(state, xp);

    // Milestones
    const milestones = checkMilestones(state, totalScore, score);
    let bonusXp = 0;
    for (const m of milestones) {
      bonusXp += m.bonusXp;
      if (!state.milestonesCompleted.includes(m.id)) {
        state.milestonesCompleted.push(m.id);
      }
    }
    state.xp += bonusXp;

    // Evolution
    const registry = JSON.parse(readFileSync(creaturesFile, "utf-8"));
    const stages = registry.evolutionLines[state.currentLineId].stages;
    const evoResult = checkEvolution(state, stages);

    let message = "";
    if (evoResult.evolved) {
      state.currentStageIndex = evoResult.newStageIndex;
      state.evolutionHistory.push({
        stageId: stages[evoResult.newStageIndex].id,
        reachedAt: new Date().toISOString().split("T")[0],
      });
      message = `${stages[evoResult.newStageIndex].name} has awakened!`;
    } else {
      // Pick suggestion from lowest dimension
      const currentStage = stages[state.currentStageIndex];
      const dims = Object.entries(score);
      dims.sort((a, b) => a[1] - b[1]);
      const weakest = dims[0][0];
      const suggestions = currentStage.suggestions[weakest];
      message = suggestions[Math.floor(Math.random() * suggestions.length)];
    }

    // Save state
    writeFileSync(stateFile, JSON.stringify(state, null, 2));

    // Write last activity for statusline bubble
    writeFileSync(activityFile, JSON.stringify({
      xp: xp + bonusXp,
      message,
      timestamp: Date.now(),
    }));

  } catch (e) {
    // Silently fail — don't break the user's prompt flow
  }
}

main();

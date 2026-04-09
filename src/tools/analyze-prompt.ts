import { randomInt } from "crypto";
import { scorePrompt, xpForScore } from "../engine/scorer.js";
import { awardXp, checkEvolution, checkMilestones } from "../engine/evolution.js";
import { renderPet, renderEvolution } from "../engine/renderer.js";
import { StateManager } from "../engine/state.js";
import { writeLastActivity } from "../engine/activity.js";
import type { CreatureRegistry, PromptScore, Milestone } from "../types.js";

interface AnalyzeResult {
  display: string;
  score: PromptScore;
  totalScore: number;
  xpAwarded: number;
  evolved: boolean;
}

export function handleAnalyzePrompt(
  text: string,
  stateManager: StateManager,
  registry: CreatureRegistry
): AnalyzeResult {
  const score = scorePrompt(text);
  const totalScore = Object.values(score).reduce((a, b) => a + b, 0);
  const xp = xpForScore(totalScore);

  const state = stateManager.loadState();
  awardXp(state, xp);

  const milestones = checkMilestones(state, totalScore, score);
  let bonusXp = 0;
  for (const m of milestones) {
    bonusXp += m.bonusXp;
    if (!state.milestonesCompleted.includes(m.id)) {
      state.milestonesCompleted.push(m.id);
    }
  }
  state.xp += bonusXp;

  const line = registry.evolutionLines[state.currentLineId];
  const stages = line.stages;
  const evoResult = checkEvolution(state, stages);

  let evolved = false;
  if (evoResult.evolved) {
    evolved = true;
    const oldName = stages[state.currentStageIndex].name;
    state.currentStageIndex = evoResult.newStageIndex;
    state.evolutionHistory.push({
      stageId: stages[evoResult.newStageIndex].id,
      reachedAt: new Date().toISOString().split("T")[0],
    });
    stateManager.saveState(state);

    const newStage = stages[evoResult.newStageIndex];
    const xpNext = evoResult.newStageIndex + 1 < stages.length
      ? stages[evoResult.newStageIndex + 1].xpRequired
      : -1;

    const display = renderEvolution(oldName, newStage, state.xp, xpNext);

    stateManager.appendPromptHistory({
      timestamp: new Date().toISOString(),
      promptSnippet: text.slice(0, 80),
      score,
      totalScore,
      xpAwarded: xp + bonusXp,
    });

    writeLastActivity(stateManager, xp + bonusXp, `${newStage.name} has awakened!`);
    return { display, score, totalScore, xpAwarded: xp + bonusXp, evolved };
  }

  stateManager.saveState(state);

  const currentStage = stages[state.currentStageIndex];
  const xpNext = state.currentStageIndex + 1 < stages.length
    ? stages[state.currentStageIndex + 1].xpRequired
    : -1;

  // Pick suggestion from the lowest-scoring dimension
  const dims = Object.entries(score) as [string, number][];
  dims.sort((a, b) => a[1] - b[1]);
  const weakest = dims[0][0] as keyof typeof currentStage.suggestions;
  const suggestions = currentStage.suggestions[weakest];
  const speech = suggestions[randomInt(suggestions.length)];

  const display = renderPet(currentStage, state.xp, xpNext, speech, milestones);

  stateManager.appendPromptHistory({
    timestamp: new Date().toISOString(),
    promptSnippet: text.slice(0, 80),
    score,
    totalScore,
    xpAwarded: xp + bonusXp,
  });

  writeLastActivity(stateManager, xp + bonusXp, speech);
  return { display, score, totalScore, xpAwarded: xp + bonusXp, evolved };
}

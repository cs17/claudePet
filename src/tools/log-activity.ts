import { StateManager } from "../engine/state.js";
import { awardXp, checkEvolution } from "../engine/evolution.js";
import { renderPet, renderEvolution } from "../engine/renderer.js";
import { writeLastActivity } from "../engine/activity.js";
import type { CreatureRegistry } from "../types.js";

const ACTIVITY_XP: Record<string, number> = {
  git_commit: 5,
  test_pass: 10,
  pr_merged: 15,
};

interface LogActivityResult {
  xpAwarded: number;
  display: string;
  evolved: boolean;
}

export function handleLogActivity(
  type: string,
  detail: string,
  stateManager: StateManager,
  registry: CreatureRegistry
): LogActivityResult {
  const xp = ACTIVITY_XP[type] ?? 0;
  const state = stateManager.loadState();
  awardXp(state, xp);

  const line = registry.evolutionLines[state.currentLineId];
  const stages = line.stages;
  const evoResult = checkEvolution(state, stages);

  if (evoResult.evolved) {
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

    return {
      xpAwarded: xp,
      display: renderEvolution(oldName, newStage, state.xp, xpNext),
      evolved: true,
    };
  }

  stateManager.saveState(state);

  const currentStage = stages[state.currentStageIndex];
  const xpNext = state.currentStageIndex + 1 < stages.length
    ? stages[state.currentStageIndex + 1].xpRequired
    : state.xp;

  const speech = `+${xp} XP for ${type.replace("_", " ")}!`;
  const display = renderPet(currentStage, state.xp, xpNext, speech, []);

  writeLastActivity(stateManager, xp, speech);
  return { xpAwarded: xp, display, evolved: false };
}

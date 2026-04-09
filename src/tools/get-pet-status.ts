import { StateManager } from "../engine/state.js";
import type { CreatureRegistry } from "../types.js";

interface PetStatusResult {
  name: string;
  level: number;
  xp: number;
  xpNext: number;
  personality: string;
  streakDays: number;
  totalPromptsScored: number;
}

export function handleGetPetStatus(
  stateManager: StateManager,
  registry: CreatureRegistry
): PetStatusResult {
  const state = stateManager.loadState();
  const line = registry.evolutionLines[state.currentLineId];
  const stage = line.stages[state.currentStageIndex];
  const xpNext = state.currentStageIndex + 1 < line.stages.length
    ? line.stages[state.currentStageIndex + 1].xpRequired
    : -1;

  return {
    name: stage.name,
    level: stage.level,
    xp: state.xp,
    xpNext,
    personality: stage.personality,
    streakDays: state.streakDays,
    totalPromptsScored: state.totalPromptsScored,
  };
}

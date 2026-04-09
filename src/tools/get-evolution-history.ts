import { StateManager } from "../engine/state.js";

interface EvolutionHistoryResult {
  history: Array<{ stageId: string; reachedAt: string }>;
}

export function handleGetEvolutionHistory(
  stateManager: StateManager
): EvolutionHistoryResult {
  const state = stateManager.loadState();
  return { history: state.evolutionHistory };
}

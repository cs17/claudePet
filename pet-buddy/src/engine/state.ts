import { readFileSync, writeFileSync, mkdirSync, existsSync } from "fs";
import { join } from "path";
import type { PetState, PromptHistoryEntry } from "../types.js";

const DEFAULT_STATE: PetState = {
  currentLineId: "titan",
  currentStageIndex: 0,
  xp: 0,
  totalPromptsScored: 0,
  streakDays: 0,
  lastActiveDate: "",
  milestonesCompleted: [],
  evolutionHistory: [],
};

const MAX_HISTORY = 50;

export class StateManager {
  private stateFile: string;
  private historyFile: string;

  constructor(readonly dataDir: string) {
    this.stateFile = join(dataDir, "state.json");
    this.historyFile = join(dataDir, "prompt-history.json");
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true });
    }
  }

  loadState(): PetState {
    if (!existsSync(this.stateFile)) return { ...DEFAULT_STATE };
    try {
      return JSON.parse(readFileSync(this.stateFile, "utf-8"));
    } catch {
      return { ...DEFAULT_STATE };
    }
  }

  saveState(state: PetState): void {
    writeFileSync(this.stateFile, JSON.stringify(state, null, 2));
  }

  loadPromptHistory(): PromptHistoryEntry[] {
    if (!existsSync(this.historyFile)) return [];
    try {
      return JSON.parse(readFileSync(this.historyFile, "utf-8"));
    } catch {
      return [];
    }
  }

  appendPromptHistory(entry: PromptHistoryEntry): void {
    const history = this.loadPromptHistory();
    history.push(entry);
    const trimmed = history.slice(-MAX_HISTORY);
    writeFileSync(this.historyFile, JSON.stringify(trimmed, null, 2));
  }
}

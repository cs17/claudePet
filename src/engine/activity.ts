import { writeFileSync } from "fs";
import { join } from "path";
import { StateManager } from "./state.js";

export function writeLastActivity(
  stateManager: StateManager,
  xpAwarded: number,
  message: string
): void {
  const file = join(stateManager.dataDir, "last-activity.json");
  writeFileSync(file, JSON.stringify({
    xp: xpAwarded,
    message,
    timestamp: Date.now(),
  }));
}

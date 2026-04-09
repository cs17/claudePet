import { mkdtempSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { handleAnalyzePrompt } from "../tools/analyze-prompt.js";
import { handleGetPetStatus } from "../tools/get-pet-status.js";
import { handleLogActivity } from "../tools/log-activity.js";
import { handleGetEvolutionHistory } from "../tools/get-evolution-history.js";
import { StateManager } from "../engine/state.js";
import type { CreatureRegistry } from "../types.js";
import { readFileSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

describe("MCP tools", () => {
  let tempDir: string;
  let stateManager: StateManager;
  let registry: CreatureRegistry;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "pet-tools-test-"));
    stateManager = new StateManager(tempDir);
    const raw = readFileSync(
      resolve(__dirname, "../data/creatures.json"),
      "utf-8"
    );
    registry = JSON.parse(raw);
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  describe("analyze-prompt", () => {
    it("should return ASCII art and score", () => {
      const result = handleAnalyzePrompt(
        "fix the bug in src/auth.ts:42",
        stateManager,
        registry
      );
      expect(result.display).toContain("┌");
      expect(result.score.specificity).toBeGreaterThan(0);
      expect(result.xpAwarded).toBeGreaterThan(0);
    });

    it("should persist XP to state", () => {
      handleAnalyzePrompt("hello", stateManager, registry);
      const state = stateManager.loadState();
      expect(state.xp).toBeGreaterThan(0);
      expect(state.totalPromptsScored).toBe(1);
    });

    it("should return evolution display when evolving", () => {
      const state = stateManager.loadState();
      state.xp = 98;
      stateManager.saveState(state);
      const result = handleAnalyzePrompt(
        "refactor the validateUser function in src/auth.ts to use zod",
        stateManager,
        registry
      );
      if (result.evolved) {
        expect(result.display).toContain("EVOLUTION");
      }
    });
  });

  describe("get-pet-status", () => {
    it("should return current pet info", () => {
      const result = handleGetPetStatus(stateManager, registry);
      expect(result.name).toBe("Larva");
      expect(result.level).toBe(1);
      expect(result.xp).toBe(0);
    });
  });

  describe("log-activity", () => {
    it("should award XP for git_commit", () => {
      const result = handleLogActivity("git_commit", "abc123", stateManager, registry);
      expect(result.xpAwarded).toBe(5);
      const state = stateManager.loadState();
      expect(state.xp).toBe(5);
    });

    it("should award XP for test_pass", () => {
      const result = handleLogActivity("test_pass", "", stateManager, registry);
      expect(result.xpAwarded).toBe(10);
    });

    it("should award XP for pr_merged", () => {
      const result = handleLogActivity("pr_merged", "#42", stateManager, registry);
      expect(result.xpAwarded).toBe(15);
    });
  });

  describe("get-evolution-history", () => {
    it("should return empty history for new pet", () => {
      const result = handleGetEvolutionHistory(stateManager);
      expect(result.history).toHaveLength(0);
    });
  });
});

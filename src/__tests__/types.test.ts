import type {
  CreatureStage,
  EvolutionLine,
  CreatureRegistry,
  PetState,
  PromptScore,
  PromptHistoryEntry,
  ScoreDimension,
  Milestone,
} from "../types.js";

describe("types", () => {
  it("should allow constructing a valid PetState", () => {
    const state: PetState = {
      currentLineId: "default",
      currentStageIndex: 0,
      xp: 0,
      totalPromptsScored: 0,
      streakDays: 0,
      lastActiveDate: "2026-04-08",
      milestonesCompleted: [],
      evolutionHistory: [],
    };
    expect(state.xp).toBe(0);
    expect(state.currentStageIndex).toBe(0);
  });

  it("should allow constructing a valid PromptScore", () => {
    const score: PromptScore = {
      specificity: 15,
      context: 10,
      actionability: 18,
      scope: 12,
      constraints: 8,
    };
    const total = Object.values(score).reduce((a, b) => a + b, 0);
    expect(total).toBe(63);
  });

  it("should allow constructing a valid CreatureStage", () => {
    const stage: CreatureStage = {
      id: "wobble_egg",
      name: "Wobble Egg",
      level: 1,
      xpRequired: 0,
      personality: "silent",
      speechStyle: "...",
      art: ["line1", "line2"],
      suggestions: {
        specificity: ["mention a file!"],
        context: ["what happened?"],
        actionability: ["what should I do?"],
        scope: ["that's a big ask"],
        constraints: ["any preferences?"],
      },
    };
    expect(stage.id).toBe("wobble_egg");
  });
});

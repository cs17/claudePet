import { checkEvolution, checkMilestones, awardXp } from "../engine/evolution.js";
import type { PetState, PromptScore, CreatureStage } from "../types.js";

const MOCK_STAGES: CreatureStage[] = [
  { id: "egg", name: "Egg", level: 1, xpRequired: 0, personality: "", speechStyle: "", art: [], suggestions: { specificity: [], context: [], actionability: [], scope: [], constraints: [] } },
  { id: "moss", name: "Mossling", level: 2, xpRequired: 100, personality: "", speechStyle: "", art: [], suggestions: { specificity: [], context: [], actionability: [], scope: [], constraints: [] } },
  { id: "ember", name: "Ember Wisp", level: 3, xpRequired: 300, personality: "", speechStyle: "", art: [], suggestions: { specificity: [], context: [], actionability: [], scope: [], constraints: [] } },
];

function makeState(overrides: Partial<PetState> = {}): PetState {
  return {
    currentLineId: "default",
    currentStageIndex: 0,
    xp: 0,
    totalPromptsScored: 0,
    streakDays: 0,
    lastActiveDate: "",
    milestonesCompleted: [],
    evolutionHistory: [],
    ...overrides,
  };
}

describe("checkEvolution", () => {
  it("should not evolve when xp is below next threshold", () => {
    const state = makeState({ xp: 50 });
    const result = checkEvolution(state, MOCK_STAGES);
    expect(result.evolved).toBe(false);
    expect(result.newStageIndex).toBe(0);
  });

  it("should evolve when xp crosses next threshold", () => {
    const state = makeState({ xp: 100 });
    const result = checkEvolution(state, MOCK_STAGES);
    expect(result.evolved).toBe(true);
    expect(result.newStageIndex).toBe(1);
  });

  it("should skip multiple stages if xp is very high", () => {
    const state = makeState({ xp: 350 });
    const result = checkEvolution(state, MOCK_STAGES);
    expect(result.evolved).toBe(true);
    expect(result.newStageIndex).toBe(2);
  });

  it("should not evolve past max stage", () => {
    const state = makeState({ currentStageIndex: 2, xp: 9999 });
    const result = checkEvolution(state, MOCK_STAGES);
    expect(result.evolved).toBe(false);
    expect(result.newStageIndex).toBe(2);
  });
});

describe("awardXp", () => {
  it("should add xp to state and increment totalPromptsScored", () => {
    const state = makeState({ xp: 50, totalPromptsScored: 5 });
    awardXp(state, 15);
    expect(state.xp).toBe(65);
    expect(state.totalPromptsScored).toBe(6);
  });

  it("should update streak on new day", () => {
    const state = makeState({
      lastActiveDate: "2026-04-07",
      streakDays: 3,
    });
    awardXp(state, 10, "2026-04-08");
    expect(state.streakDays).toBe(4);
    expect(state.lastActiveDate).toBe("2026-04-08");
  });

  it("should reset streak if more than 1 day gap", () => {
    const state = makeState({
      lastActiveDate: "2026-04-05",
      streakDays: 3,
    });
    awardXp(state, 10, "2026-04-08");
    expect(state.streakDays).toBe(1);
  });
});

describe("checkMilestones", () => {
  it("should award first_75 milestone", () => {
    const state = makeState({ milestonesCompleted: [] });
    const milestones = checkMilestones(state, 80);
    expect(milestones.some((m) => m.id === "first_75")).toBe(true);
  });

  it("should not repeat one-time milestones", () => {
    const state = makeState({ milestonesCompleted: ["first_75"] });
    const milestones = checkMilestones(state, 80);
    expect(milestones.some((m) => m.id === "first_75")).toBe(false);
  });

  it("should award 100_prompts milestone", () => {
    const state = makeState({
      totalPromptsScored: 100,
      milestonesCompleted: [],
    });
    const milestones = checkMilestones(state, 50);
    expect(milestones.some((m) => m.id === "100_prompts")).toBe(true);
  });

  it("should award streak_10 milestone", () => {
    const state = makeState({
      streakDays: 10,
      milestonesCompleted: [],
    });
    const milestones = checkMilestones(state, 50);
    expect(milestones.some((m) => m.id === "streak_10")).toBe(true);
  });

  it("should award perfect_prompt as repeatable", () => {
    const state = makeState({ milestonesCompleted: ["perfect_prompt"] });
    const score: PromptScore = {
      specificity: 16,
      context: 17,
      actionability: 15,
      scope: 18,
      constraints: 16,
    };
    const milestones = checkMilestones(state, 82, score);
    expect(milestones.some((m) => m.id === "perfect_prompt")).toBe(true);
  });
});

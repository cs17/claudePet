import { renderPet, renderEvolution } from "../engine/renderer.js";
import type { CreatureStage } from "../types.js";

const MOCK_STAGE: CreatureStage = {
  id: "shadowcat",
  name: "Shadowcat",
  level: 4,
  xpRequired: 600,
  personality: "sarcastic",
  speechStyle: "dry wit",
  art: [
    "  /\\_/\\    ",
    " ( o.o )   ",
    "  > ^ <    ",
    " /|   |\\   ",
  ],
  suggestions: {
    specificity: ["Which file, exactly?"],
    context: ["And then what happened?"],
    actionability: ["What do you want me to DO?"],
    scope: ["That's... ambitious."],
    constraints: ["Any rules I should know?"],
  },
};

describe("renderPet", () => {
  it("should contain the creature name and level", () => {
    const output = renderPet(MOCK_STAGE, 650, 1000, "Nice one!", []);
    expect(output).toContain("Shadowcat");
    expect(output).toContain("Lv.4");
  });

  it("should contain the speech bubble text", () => {
    const output = renderPet(MOCK_STAGE, 650, 1000, "Try a file path!", []);
    expect(output).toContain("Try a file path!");
  });

  it("should contain XP values", () => {
    const output = renderPet(MOCK_STAGE, 650, 1000, "Hi", []);
    expect(output).toContain("650");
    expect(output).toContain("1000");
  });

  it("should contain box borders", () => {
    const output = renderPet(MOCK_STAGE, 0, 100, "Hi", []);
    expect(output).toContain("┌");
    expect(output).toContain("┘");
  });

  it("should contain ASCII art lines", () => {
    const output = renderPet(MOCK_STAGE, 0, 100, "Hi", []);
    expect(output).toContain("/\\_/\\");
  });
});

describe("renderEvolution", () => {
  it("should show evolution header", () => {
    const output = renderEvolution("Mossling", MOCK_STAGE, 600, 1000);
    expect(output).toContain("EVOLUTION");
  });

  it("should show old creature name transforming", () => {
    const output = renderEvolution("Mossling", MOCK_STAGE, 600, 1000);
    expect(output).toContain("Mossling");
    expect(output).toContain("transforming");
  });

  it("should show new creature art and name", () => {
    const output = renderEvolution("Mossling", MOCK_STAGE, 600, 1000);
    expect(output).toContain("Shadowcat");
    expect(output).toContain("/\\_/\\");
  });
});

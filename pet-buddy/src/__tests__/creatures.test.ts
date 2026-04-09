import { readFileSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import type { CreatureRegistry, ScoreDimension } from "../types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

const DIMENSIONS: ScoreDimension[] = [
  "specificity",
  "context",
  "actionability",
  "scope",
  "constraints",
];

describe("creatures.json", () => {
  let registry: CreatureRegistry;

  beforeAll(() => {
    const raw = readFileSync(
      resolve(__dirname, "../data/creatures.json"),
      "utf-8"
    );
    registry = JSON.parse(raw);
  });

  it("should have at least one evolution line", () => {
    const lines = Object.keys(registry.evolutionLines);
    expect(lines.length).toBeGreaterThan(0);
  });

  it("should have 5 stages per line", () => {
    for (const line of Object.values(registry.evolutionLines)) {
      expect(line.stages).toHaveLength(5);
    }
  });

  it("should have ascending xpRequired", () => {
    for (const line of Object.values(registry.evolutionLines)) {
      for (let i = 1; i < line.stages.length; i++) {
        expect(line.stages[i].xpRequired).toBeGreaterThan(line.stages[i - 1].xpRequired);
      }
    }
  });

  it("should have ascending levels 1-5", () => {
    for (const line of Object.values(registry.evolutionLines)) {
      line.stages.forEach((s, i) => expect(s.level).toBe(i + 1));
    }
  });

  it("every stage should have suggestions for all 5 dimensions", () => {
    for (const line of Object.values(registry.evolutionLines)) {
      line.stages.forEach((s) => {
        DIMENSIONS.forEach((d) => {
          expect(s.suggestions[d].length).toBeGreaterThan(0);
        });
      });
    }
  });

  it("every stage should have unique id within its line", () => {
    for (const line of Object.values(registry.evolutionLines)) {
      const ids = line.stages.map((s) => s.id);
      expect(new Set(ids).size).toBe(ids.length);
    }
  });
});

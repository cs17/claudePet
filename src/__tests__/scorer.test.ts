import { scorePrompt, xpForScore } from "../engine/scorer.js";

describe("scorePrompt", () => {
  it("should score a vague prompt low", () => {
    const score = scorePrompt("fix the bug");
    const total =
      score.specificity +
      score.context +
      score.actionability +
      score.scope +
      score.constraints;
    expect(total).toBeLessThan(30);
  });

  it("should score a detailed prompt high", () => {
    const score = scorePrompt(
      "Refactor the validateUser function in src/auth/validator.ts:42 to use zod schema validation instead of manual checks. Currently it returns undefined on invalid input but should throw a ValidationError. Keep the function under 30 lines."
    );
    const total =
      score.specificity +
      score.context +
      score.actionability +
      score.scope +
      score.constraints;
    expect(total).toBeGreaterThan(60);
  });

  it("should give high specificity when file paths are mentioned", () => {
    const score = scorePrompt("look at src/index.ts line 42");
    expect(score.specificity).toBeGreaterThanOrEqual(10);
  });

  it("should give high actionability for clear verbs", () => {
    const score = scorePrompt("refactor this function to use async/await");
    expect(score.actionability).toBeGreaterThanOrEqual(10);
  });

  it("should give high constraints for tech mentions", () => {
    const score = scorePrompt("use zod for validation, keep it under 50 lines");
    expect(score.constraints).toBeGreaterThanOrEqual(10);
  });

  it("should penalize overly broad scope", () => {
    const score = scorePrompt("rewrite the entire application from scratch");
    expect(score.scope).toBeLessThan(10);
  });

  it("should cap each dimension at 20", () => {
    const score = scorePrompt(
      "In src/auth/validator.ts:42-60, the validateUser function throws TypeError when email is null. Expected: return ValidationError. Fix the null check on line 45 using zod .nullable(). Refactor to async. Use TypeScript strict mode. Keep under 20 lines. Add unit test."
    );
    Object.values(score).forEach((v) => {
      expect(v).toBeLessThanOrEqual(20);
    });
  });
});

describe("xpForScore", () => {
  it("should return 2 for score 0-20", () => {
    expect(xpForScore(15)).toBe(2);
  });
  it("should return 8 for score 21-50", () => {
    expect(xpForScore(35)).toBe(8);
  });
  it("should return 15 for score 51-75", () => {
    expect(xpForScore(60)).toBe(15);
  });
  it("should return 25 for score 76-100", () => {
    expect(xpForScore(85)).toBe(25);
  });
});

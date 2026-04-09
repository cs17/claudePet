import type { PromptScore } from "../types.js";

const FILE_PATH_PATTERN = /(?:[\w/\\-]+(?:\.[\w/\\-]+)*\.\w{1,5})|(?:line\s*\d+)|(?::\d+)/gi;
const FUNCTION_PATTERN = /(?:function|method|class|variable|const|let|var)\s+\w+|\w+\(\)/gi;
const ACTION_VERBS = /\b(fix|refactor|add|create|remove|delete|update|change|move|rename|extract|implement|write|build|test|debug|optimize|replace|migrate|convert|split|merge|wrap)\b/gi;
const CONTEXT_MARKERS = /\b(because|currently|expected|actual|instead|but|however|when|after|before|error|returns|throws|fails|broken|wrong|should)\b/gi;
const CONSTRAINT_MARKERS = /\b(use|using|with|without|under|max|limit|only|must|keep|avoid|prefer|follow|pattern|style|convention)\b/gi;
const TECH_TERMS = /\b(typescript|javascript|react|node|zod|jest|async|await|sql|api|rest|graphql|css|html|json|yaml|docker|git|npm|pnpm)\b/gi;
const BROAD_SCOPE = /\b(entire|whole|everything|all files|from scratch|complete rewrite|rebuild)\b/gi;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function countMatches(text: string, pattern: RegExp): number {
  return (text.match(pattern) || []).length;
}

function scoreSpecificity(text: string): number {
  let score = 0;
  score += Math.min(countMatches(text, FILE_PATH_PATTERN) * 5, 12);
  score += Math.min(countMatches(text, FUNCTION_PATTERN) * 4, 8);
  return clamp(score, 0, 20);
}

function scoreContext(text: string): number {
  let score = 0;
  score += Math.min(countMatches(text, CONTEXT_MARKERS) * 3, 12);
  const sentences = text.split(/[.!?\n]/).filter((s) => s.trim().length > 10);
  score += Math.min(sentences.length * 2, 8);
  return clamp(score, 0, 20);
}

function scoreActionability(text: string): number {
  let score = 0;
  score += Math.min(countMatches(text, ACTION_VERBS) * 5, 15);
  const hasImperative = /^(fix|refactor|add|create|remove|update|change|move|write|build|test|implement)\b/i.test(text.trim());
  if (hasImperative) score += 5;
  return clamp(score, 0, 20);
}

function scoreScope(text: string): number {
  let score = 14;
  score -= countMatches(text, BROAD_SCOPE) * 6;
  const wordCount = text.split(/\s+/).length;
  if (wordCount < 4) score -= 6;
  if (wordCount >= 10 && wordCount <= 60) score += 4;
  if (wordCount > 100) score -= 2;
  return clamp(score, 0, 20);
}

function scoreConstraints(text: string): number {
  let score = 0;
  score += Math.min(countMatches(text, CONSTRAINT_MARKERS) * 3, 10);
  score += Math.min(countMatches(text, TECH_TERMS) * 3, 10);
  return clamp(score, 0, 20);
}

export function scorePrompt(text: string): PromptScore {
  return {
    specificity: scoreSpecificity(text),
    context: scoreContext(text),
    actionability: scoreActionability(text),
    scope: scoreScope(text),
    constraints: scoreConstraints(text),
  };
}

export function xpForScore(totalScore: number): number {
  if (totalScore <= 20) return 2;
  if (totalScore <= 50) return 8;
  if (totalScore <= 75) return 15;
  return 25;
}

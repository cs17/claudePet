import type { CreatureStage, Milestone } from "../types.js";

function xpBar(current: number, next: number, width: number = 14): string {
  const ratio = next > 0 ? Math.min(current / next, 1) : 1;
  const filled = Math.round(ratio * width);
  return "█".repeat(filled) + "░".repeat(width - filled);
}

export function renderPet(
  stage: CreatureStage,
  xp: number,
  xpNext: number,
  speech: string,
  milestones: Milestone[]
): string {
  const speechLines = wrapText(speech, 24);
  const bubbleWidth = Math.max(...speechLines.map((l) => l.length)) + 2;
  const bubbleTop = "┌" + "─".repeat(bubbleWidth) + "┐";
  const bubbleBot = "└" + "─".repeat(bubbleWidth) + "┘";
  const bubbleBody = speechLines.map(
    (l) => "│ " + l.padEnd(bubbleWidth - 2) + " │"
  );

  const artLines = [...stage.art];
  const speechBlock = [bubbleTop, ...bubbleBody, bubbleBot];

  const contentLines: string[] = [];
  const maxArtWidth = Math.max(...artLines.map((l) => visualLength(l)));
  const padArt = maxArtWidth + 4;

  for (let i = 0; i < Math.max(artLines.length, speechBlock.length); i++) {
    const artPart = (artLines[i] || "").padEnd(padArt);
    const speechPart = speechBlock[i] || "";
    contentLines.push(artPart + speechPart);
  }

  contentLines.push("");
  contentLines.push(`◆ ${stage.name} Lv.${stage.level}`);
  contentLines.push(xpNext < 0
    ? `♥ ${xpBar(xp, 1, 14)} ${xp} XP (MAX)`
    : `♥ ${xpBar(xp, xpNext)} ${xp}/${xpNext} XP`);

  if (milestones.length > 0) {
    contentLines.push("");
    for (const m of milestones) {
      contentLines.push(`★ ${m.name}! +${m.bonusXp} XP`);
    }
  }

  return boxWrap(contentLines);
}

export function renderEvolution(
  oldName: string,
  newStage: CreatureStage,
  xp: number,
  xpNext: number
): string {
  const lines: string[] = [
    "",
    "  ✧ ･ﾟ: *✧ EVOLUTION ✧*:ﾟ･ ✧",
    "",
    `    ${oldName} is transforming...`,
    "",
    ...newStage.art.map((l) => "    " + l),
    "",
    `    ✦ ${newStage.name} has awakened! ✦`,
    "",
    `◆ ${newStage.name} Lv.${newStage.level}`,
    xpNext < 0
      ? `♥ ${xpBar(xp, 1, 14)} ${xp} XP (MAX)`
      : `♥ ${xpBar(xp, xpNext)} ${xp}/${xpNext} XP`,
  ];

  return boxWrap(lines);
}

function boxWrap(lines: string[]): string {
  const maxLen = Math.max(...lines.map((l) => visualLength(l)));
  const width = maxLen + 4;
  const top = "┌" + "─".repeat(width) + "┐";
  const bot = "└" + "─".repeat(width) + "┘";
  const body = lines.map(
    (l) => "│  " + l + " ".repeat(maxLen - visualLength(l)) + "  │"
  );
  return [top, ...body, bot].join("\n");
}

function visualLength(str: string): number {
  const stripped = str.replace(/\x1b\[[0-9;]*m/g, "");
  let len = 0;
  for (const ch of stripped) {
    const code = ch.codePointAt(0) || 0;
    if (code > 0x2e80) len += 2;
    else len += 1;
  }
  return len;
}

function wrapText(text: string, maxWidth: number): string[] {
  const words = text.split(" ");
  const lines: string[] = [];
  let current = "";
  for (const word of words) {
    if (current.length + word.length + 1 > maxWidth && current.length > 0) {
      lines.push(current);
      current = word;
    } else {
      current = current ? current + " " + word : word;
    }
  }
  if (current) lines.push(current);
  return lines;
}

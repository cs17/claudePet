import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { StateManager } from "./engine/state.js";
import { handleAnalyzePrompt } from "./tools/analyze-prompt.js";
import { handleGetPetStatus } from "./tools/get-pet-status.js";
import { handleLogActivity } from "./tools/log-activity.js";
import { handleGetEvolutionHistory } from "./tools/get-evolution-history.js";
import type { CreatureRegistry } from "./types.js";
import { readFileSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import { homedir } from "os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_DIR = resolve(homedir(), ".claude", "claude-pet");
const stateManager = new StateManager(DATA_DIR);
const registry: CreatureRegistry = JSON.parse(
  readFileSync(resolve(__dirname, "data", "creatures.json"), "utf-8")
);

const server = new McpServer({
  name: "claude-pet",
  version: "0.1.0",
});

server.tool(
  "analyze_prompt",
  "Score a prompt for quality, award XP to your pet, and get improvement suggestions",
  { text: z.string().describe("The prompt text to analyze") },
  async ({ text }) => {
    const result = handleAnalyzePrompt(text, stateManager, registry);
    return {
      content: [{ type: "text" as const, text: result.display }],
    };
  }
);

server.tool(
  "get_pet_status",
  "Get your pet's current status, level, XP, and form",
  {},
  async () => {
    const result = handleGetPetStatus(stateManager, registry);
    return {
      content: [
        {
          type: "text" as const,
          text: `${result.name} (Lv.${result.level}) — ${result.xpNext < 0 ? `${result.xp} XP (MAX)` : `${result.xp}/${result.xpNext} XP`}\nPersonality: ${result.personality}\nStreak: ${result.streakDays} days`,
        },
      ],
    };
  }
);

server.tool(
  "log_activity",
  "Log a coding activity (git_commit, test_pass, pr_merged) to award bonus XP",
  {
    type: z.enum(["git_commit", "test_pass", "pr_merged"]).describe("Activity type"),
    detail: z.string().optional().describe("Optional detail (commit hash, PR number)"),
  },
  async ({ type, detail }) => {
    const result = handleLogActivity(type, detail || "", stateManager, registry);
    return {
      content: [{ type: "text" as const, text: result.display }],
    };
  }
);

server.tool(
  "get_evolution_history",
  "See your pet's evolution history and past forms",
  {},
  async () => {
    const result = handleGetEvolutionHistory(stateManager);
    return {
      content: [{ type: "text" as const, text: JSON.stringify(result, null, 2) }],
    };
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);

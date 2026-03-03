/**
 * Build-time script: generates the AI system prompt from the JS catalog.
 *
 * Bundled by esbuild (json_render_prompt profile) then executed with Node to
 * produce priv/json_render_prompt.txt.  The Elixir module
 * Liteskill.BuiltinTools.VisualResponse reads this file at compile time via
 * @external_resource, keeping the JS catalog as the single source of truth.
 *
 * Usage (via mix alias):
 *   mix gen.jr_prompt
 */
import { catalog } from "./catalog.js"
import { writeFileSync } from "node:fs"

const prompt = catalog.prompt({
  mode: "chat",
  customRules: [
    "NEVER use viewport-height classes (h-screen, min-h-screen). The UI renders inline in a chat message, not as a full page.",
    "Prefer Grid with columns=2 or columns=3 for dashboards and multi-panel layouts.",
    "Always include realistic, varied sample data. Never leave arrays empty.",
    "Keep visual responses focused and appropriately sized for inline chat display.",
  ],
})

writeFileSync("priv/json_render_prompt.txt", prompt)
console.log("Generated priv/json_render_prompt.txt")

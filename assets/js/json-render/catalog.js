import { defineCatalog } from "@json-render/core"
import { schema } from "@json-render/react/schema"
import { z } from "zod"

/**
 * Component catalog for visual responses in the chat UI.
 *
 * This is the SINGLE SOURCE OF TRUTH for component definitions.
 * At build time, `mix gen.jr_prompt` calls `catalog.prompt()` to generate
 * the AI system prompt (priv/json_render_prompt.txt), which the Elixir
 * module Liteskill.BuiltinTools.VisualResponse reads at compile time.
 *
 * To add/remove/modify components:
 *   1. Edit this file (schema definitions)
 *   2. Update registry.jsx (React implementations)
 *   3. Run `mix gen.jr_prompt` to regenerate the prompt
 */
export const catalog = defineCatalog(schema, {
  components: {
    Card: {
      props: z.object({
        title: z.string(),
        description: z.string().nullable().optional(),
        padding: z.enum(["sm", "md", "lg"]).nullable().optional(),
      }),
      slots: ["default"],
      description: "Container card for grouping content",
    },
    Metric: {
      props: z.object({
        label: z.string(),
        value: z.string(),
        format: z.enum(["currency", "percent", "number"]).nullable().optional(),
        trend: z.enum(["up", "down", "flat"]).nullable().optional(),
      }),
      slots: [],
      description: "Display a single KPI or metric value with label",
    },
    Table: {
      props: z.object({
        headers: z.array(z.string()),
        rows: z.array(z.array(z.string())),
        caption: z.string().nullable().optional(),
      }),
      slots: [],
      description: "Data table with headers and rows",
    },
    BarChart: {
      props: z.object({
        labels: z.array(z.string()),
        values: z.array(z.number()),
        title: z.string().nullable().optional(),
        direction: z.enum(["horizontal", "vertical"]).nullable().optional(),
        color: z.string().nullable().optional(),
      }),
      slots: [],
      description: "Bar chart for comparing values",
    },
    LineChart: {
      props: z.object({
        labels: z.array(z.string()),
        values: z.array(z.number()),
        title: z.string().nullable().optional(),
        color: z.string().nullable().optional(),
      }),
      slots: [],
      description: "Line chart for showing trends",
    },
    PieChart: {
      props: z.object({
        labels: z.array(z.string()),
        values: z.array(z.number()),
        title: z.string().nullable().optional(),
      }),
      slots: [],
      description: "Pie chart for showing proportional data",
    },
    List: {
      props: z.object({
        items: z.array(z.string()),
        ordered: z.boolean().nullable().optional(),
        title: z.string().nullable().optional(),
      }),
      slots: [],
      description: "Ordered or unordered list of items",
    },
    Alert: {
      props: z.object({
        message: z.string(),
        severity: z.enum(["info", "success", "warning", "error"]),
        title: z.string().nullable().optional(),
      }),
      slots: [],
      description: "Alert/callout box for important messages",
    },
    Progress: {
      props: z.object({
        label: z.string(),
        value: z.number(),
        color: z.string().nullable().optional(),
      }),
      slots: [],
      description: "Progress bar showing completion percentage",
    },
    Badge: {
      props: z.object({
        text: z.string(),
        variant: z.enum(["default", "primary", "success", "warning", "error"]).nullable().optional(),
      }),
      slots: [],
      description: "Small status indicator badge/tag",
    },
    Stack: {
      props: z.object({
        direction: z.enum(["vertical", "horizontal"]).nullable().optional(),
        gap: z.enum(["sm", "md", "lg"]).nullable().optional(),
        align: z.enum(["start", "center", "end", "stretch"]).nullable().optional(),
      }),
      slots: ["default"],
      description: "Layout container that stacks children",
    },
    Grid: {
      props: z.object({
        columns: z.number(),
        gap: z.enum(["sm", "md", "lg"]).nullable().optional(),
      }),
      slots: ["default"],
      description: "CSS grid layout with configurable columns",
    },
    Button: {
      props: z.object({
        label: z.string(),
        variant: z.enum(["primary", "secondary", "ghost"]).nullable().optional(),
        disabled: z.boolean().nullable().optional(),
      }),
      slots: [],
      description: "Clickable button element (display only)",
    },
  },
  actions: {},
})

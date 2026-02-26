# Agent Studio

The Agent Studio lets users define reusable AI agents with specific configurations, tool access, and data source access.

## Agent Definitions

Each agent definition includes:

- **Name** and **backstory** — Identity and persona
- **Strategy** — Behavioral approach (`react`, `chain_of_thought`, `tree_of_thoughts`, `direct`)
- **Opinions** — Behavioral guidance and perspective
- **LLM model** — The model the agent uses for inference
- **System prompt** — Optional per-agent system prompt override
- **Tool access** — ACL-controlled access to specific MCP servers
- **Data source access** — ACL-controlled access to specific data sources for RAG

## Tool Access

Agents are granted access to MCP servers via ACLs on the `mcp_server` entity type. During execution, the `ToolResolver` resolves which tools the agent can use based on its ACLs.

## Data Source Access

Similarly, agents can be granted access to data sources. During runs, the agent's RAG context is scoped to only the data sources it has access to.

## Teams

Agents can be composed into teams with different topologies:

- **Sequential (Pipeline)** — Agents execute in order, passing results forward. Later agents see the accumulated context from prior stages.
- **Parallel** — Agents execute concurrently
- **Supervisor** — A supervisor agent coordinates other agents

Team members are position-ordered and assigned roles (lead, analyst, reviewer, editor).

## Execution

Agents execute through the `Runs` system. A run tracks the full lifecycle of an agent or team execution, including:

- **Prompt** — Input for the pipeline
- **Logs** — Structured execution logs with level, step, message, and metadata
- **Tasks** — Individual task tracking within a run
- **Usage** — Token/cost accounting per run
- **Report** — Optional deliverable report generated from the run output

## Jido Integration

Under the hood, agent execution uses the [Jido](https://hex.pm/packages/jido) framework (v2.0) for structured agent actions and workflows. The `LlmGenerate` action provides a synchronous agentic loop with tool calling, context pruning, and cost limits.

## Access Control

Agent definitions use the standard ACL system:

- Creator is the owner
- Access can be granted to other users
- Only accessible agents appear in the agent list

## Routes

- `/agents` — Agent Studio landing page
- `/agents/list` — List all agents
- `/agents/new` — Create a new agent
- `/agents/:agent_id` — View agent details
- `/agents/:agent_id/edit` — Edit an agent
- `/teams` — List teams
- `/teams/new` — Create a new team
- `/teams/:team_id` — View/edit a team
- `/runs` — List runs
- `/runs/new` — Start a new run
- `/runs/:run_id` — View run details and logs

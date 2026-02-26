# Agents Context

`Liteskill.Agents` manages agent definitions — the "character sheets" for AI agents.

## Boundary

```elixir
use Boundary,
  top_level?: true,
  deps: [Liteskill.Authorization, Liteskill.Rbac, Liteskill.McpServers, Liteskill.LLM, Liteskill.LlmGateway, Liteskill.Usage, Liteskill.LlmModels, Liteskill.Rag, Liteskill.DataSources],
  exports: [AgentDefinition, ToolResolver, JidoAgent, Actions.LlmGenerate]
```

## Agent CRUD

| Function | Description |
|----------|-------------|
| `create_agent(attrs)` | Creates with RBAC check, model validation, and owner ACL |
| `update_agent(id, user_id, attrs)` | Updates (owner only) |
| `delete_agent(id, user_id)` | Deletes (owner only) |
| `list_agents(user_id)` | Lists accessible agents (owned + ACL'd) |
| `get_agent(id, user_id)` | Gets with access check |

## Tool Access

Agents are granted access to MCP servers via entity ACLs:

| Function | Description |
|----------|-------------|
| `grant_tool_access(agent_id, mcp_server_id, user_id)` | Grant MCP server access |
| `revoke_tool_access(agent_id, mcp_server_id, user_id)` | Revoke MCP server access |
| `list_tool_server_ids(agent_id)` | List accessible server IDs |
| `list_accessible_servers(agent_id)` | List accessible server structs |

## Data Source Access

Agents can also be granted access to data sources for RAG:

| Function | Description |
|----------|-------------|
| `grant_source_access(agent_id, source_id, user_id)` | Grant data source access |
| `revoke_source_access(agent_id, source_id, user_id)` | Revoke data source access |
| `list_source_ids(agent_id)` | List accessible source IDs |

## Model Validation

When creating or updating an agent with an `llm_model_id`, the context validates that the user has access to that model via `LlmModels.get_model/2`.

## Tool Resolution

`Liteskill.Agents.ToolResolver` resolves the set of tools available to an agent at execution time by querying its MCP server ACLs and fetching tool lists from each accessible server.

## Execution

Agent execution is handled by `Liteskill.Agents.Actions.LlmGenerate`, which provides a synchronous agentic loop:

1. Build messages from context
2. Send to LLM with available tools
3. If LLM requests tool calls, execute them and loop
4. Apply context pruning if needed
5. Enforce cost limits per run

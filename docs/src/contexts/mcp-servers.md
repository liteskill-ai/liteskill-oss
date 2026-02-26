# MCP Servers Context

`Liteskill.McpServers` manages MCP server registrations and user tool selections.

## Boundary

```elixir
use Boundary,
  top_level?: true,
  deps: [Liteskill.Authorization, Liteskill.Rbac, Liteskill.BuiltinTools, Liteskill.Settings],
  exports: [McpServer, Client, UserToolSelection]
```

## Server CRUD

| Function | Description |
|----------|-------------|
| `list_servers(user_id)` | Lists accessible servers (owned + global + ACL'd) plus built-in |
| `get_server(id, user_id)` | Gets a server by ID with access check |
| `create_server(attrs)` | Creates a server with RBAC check and owner ACL |
| `update_server(server, user_id, attrs)` | Updates (owner only) |
| `delete_server(id, user_id)` | Deletes (owner only) |

## Built-in Servers

Virtual servers prefixed with `builtin:` are defined in code (`Liteskill.BuiltinTools`) and merged into the server list. They cannot be modified or deleted.

## Tool Selections

Users select which servers are active for their conversations:

| Function | Description |
|----------|-------------|
| `load_selected_server_ids(user_id)` | Loads selections, prunes stale entries |
| `select_server(user_id, server_id)` | Persists a selection (idempotent) |
| `deselect_server(user_id, server_id)` | Removes a selection |
| `clear_selected_servers(user_id)` | Removes all selections |

## Client

`Liteskill.McpServers.Client` implements JSON-RPC 2.0 over HTTP:

- `list_tools(server, opts)` — Discovers available tools
- `call_tool(server, tool_name, arguments, opts)` — Executes a tool call

Features:
- MCP initialization handshake (initialize → initialized → request)
- Automatic retry with exponential backoff (up to 2 retries)
- Session ID tracking via `mcp-session-id` header
- Custom header support with blocked header filtering for security
- API key authentication via `Authorization: Bearer <key>` header

# Adding your first MCP Server

MCP (Model Context Protocol) servers give your LLM access to external tools. When an MCP server is connected, the LLM can request tool calls during conversation streaming, and Liteskill will execute them automatically or with user approval.

## Prerequisites

- Liteskill running (see [Initial Setup](quick-start.md))
- An MCP server accessible via HTTP(S)

## Register an MCP Server

1. Navigate to `Tools` in the sidebar (or go to `/mcp`).
1. Click the "Add Server" button.
1. Fill in the server details:
    - **Name**: A display name for the server (e.g. "My Tools")
    - **URL**: The HTTP(S) endpoint of your MCP server
    - **API Key** (optional): If your server requires authentication
    - **Custom Headers** (optional): Any additional headers your server needs
1. Click Save.

Liteskill will connect to the server and discover its available tools via the `tools/list` JSON-RPC call.

## Select the Server for Conversations

After registering the server, you need to select it for use in your conversations:

1. Start or continue a conversation.
1. Click the Tool icon to the left of "Type a message..." in the chat window.
1. Select the tools you'd like to use.
1. By default, tool calls execute automatically (`auto_confirm: true`).
1. When the LLM determines it needs to use a tool, it will emit a tool call request.

Tool calls appear in the conversation as collapsible sections showing the tool name, arguments, and result.

## Docker Networking

If you're running Liteskill via Docker Compose (which uses `network_mode: host`), MCP servers on your host machine are reachable at `localhost`:

```
http://localhost:4005
```

This requires **Allow private MCP URLs** to be enabled in server settings (`Admin > Setup`), since `localhost` resolves to a private address.

## SSRF Protection

By default, only HTTPS URLs are accepted for MCP servers, and private/reserved addresses are blocked. To allow private URLs for self-hosted MCP servers, enable **Allow private MCP URLs** in the admin settings.

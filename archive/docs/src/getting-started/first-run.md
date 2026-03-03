# First Run

## Initial Setup

On first boot, Liteskill:

1. Validates the encryption key (`ENCRYPTION_KEY` env var or auto-generated in desktop mode)
2. Creates ETS tables for rate limiting and LLM token buckets
3. Ensures a root admin user exists (`admin@liteskill.local`)
4. Bootstraps system RBAC roles
5. Ensures environment-configured providers are created (e.g. AWS Bedrock via `AWS_BEARER_TOKEN_BEDROCK`)
6. Loads application settings

## Admin Setup

Navigate to [http://localhost:4000/setup](http://localhost:4000/setup) to set the admin password. This route is only available when the admin user hasn't been configured yet.

After setup, log in at [http://localhost:4000/login](http://localhost:4000/login).

## Configuring LLM Providers

Before you can chat, configure at least one LLM provider:

1. Go to **Admin > Providers** (`/admin/providers`)
2. Add a provider (e.g. Amazon Bedrock, OpenRouter, or any OpenAI-compatible endpoint)
3. Go to **Admin > Models** (`/admin/models`) and add models under that provider

Users can also add personal providers at **Profile > Providers** (`/profile/providers`).

## Configuring MCP Servers

To enable tool calling:

1. Go to **MCP Servers** (`/mcp`)
2. Add an MCP server URL with optional API key and custom headers
3. The server's tools will be available in conversations when selected

## Configuring RAG

To enable document-augmented conversations:

1. Go to **Admin > RAG** (`/admin/rag`) and configure the default embedding model
2. Navigate to **Sources** (`/sources`) to create collections and add documents
3. Documents are automatically chunked and embedded for semantic search

# LLM Providers

Liteskill supports multiple LLM providers through a pluggable provider system powered by ReqLLM.

## Provider Types

Providers are configured in the database via the admin UI. ReqLLM supports 56+ providers including:

- **Amazon Bedrock** — AWS-hosted models (Claude, Llama, etc.)
- **OpenRouter** — Multi-model gateway with OAuth PKCE support
- **OpenAI-compatible** — Any endpoint that speaks the OpenAI API format (vLLM, LiteLLM, etc.)
- **Anthropic** — Direct Anthropic API access
- **Google** — Gemini models via Google AI
- **Azure OpenAI** — Azure-hosted OpenAI models

## Provider Configuration

Each provider record stores:

- **Name** — Display name
- **Provider type** — Determines the API protocol
- **API key** — Encrypted at rest via `Liteskill.Crypto`
- **Base URL** — Optional override for custom endpoints (e.g. LiteLLM proxies, local vLLM)
- **Provider config** — Type-specific settings (e.g. AWS region, Azure deployment ID)
- **Instance-wide flag** — If true, available to all users
- **Status** — Active or inactive

## Access Control

- **Instance-wide providers** are available to all users
- **User-owned providers** are private to their creator (configured at `/profile/providers`)
- **Admin-granted access** — Admins can grant `viewer` role on a provider to specific users via ACLs

## Models

Models are defined under providers. Each model specifies:

- **Model ID** — The provider's model identifier (e.g. `anthropic/claude-3-5-haiku`)
- **Display name** — Shown in the UI
- **Model type** — `inference`, `embedding`, or `rerank`
- **Cost rates** — Input/output cost per million tokens
- **Context window** — Maximum token limit
- **Instance-wide flag** — Available to all users when set
- **Active/inactive status**

Users select models when creating conversations or configuring agents.

## Environment-Based Providers

On boot, Liteskill checks for environment variables and auto-creates providers:

- `AWS_BEARER_TOKEN_BEDROCK` + `AWS_REGION` — Creates an instance-wide Bedrock provider

## LLM Gateway

The LLM Gateway provides per-provider infrastructure:

- **Circuit breaker** — Tracks failures per provider and opens the circuit after a threshold, preventing cascading failures
- **Concurrency gates** — Limits concurrent requests per provider
- **Token bucket** — ETS-based rate limiting with periodic cleanup

## ReqLLM Configuration

ReqLLM connection pools and timeouts are configured in `config/runtime.exs`:

- Stream receive timeout: 120 seconds (accommodates tool-calling rounds)
- HTTP/1.1 pool with 25 connections

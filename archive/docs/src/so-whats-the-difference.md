# So What's the Difference?

If you're evaluating self-hosted AI tools, you've probably noticed the space is crowded. Chat UIs, API gateways, workflow engines, wiki platforms, agent frameworks - there's no shortage of options, and each one solves a piece of the puzzle. Liteskill was built to be the whole puzzle.

This page explains what makes Liteskill different from the categories of tools you'll encounter, and why those differences matter.

---

## vs. Chat Interfaces

Most open-source LLM chat UIs give you a clean frontend for talking to models. They handle streaming, multi-model switching, and sometimes RAG. But they're built on standard CRUD persistence - conversations are mutable rows in a database.

**What Liteskill does differently:**

- **Event-sourced conversations.** Every state change is captured as an immutable event. You get a full audit trail, state replay, and temporal queries. For regulated industries, this is table stakes.
- **Per-resource access control.** Most chat UIs offer role-based permissions (admin vs. user). Liteskill provides granular ACLs on individual conversations, reports, agents, wiki spaces, and more - with owner, manager, editor, and viewer roles, plus group-based grants.
- **Native MCP tool integration.** Rather than a proprietary plugin system, Liteskill speaks the open Model Context Protocol over JSON-RPC 2.0. Any MCP-compliant tool server works without custom integration code.
- **Agent Studio & Teams.** Beyond personas and system prompts, Liteskill provides composable agents with strategies (ReAct, chain-of-thought, tree-of-thoughts), team topologies (sequential, parallel, supervisor), and full execution tracking with cost limits.
- **Conversation forking.** Branch off at any point in a conversation to explore alternate paths without losing the original thread.

---

## vs. LLM Proxy Gateways

API gateways sit between your application and LLM providers, offering a unified interface, load balancing, rate limiting, and cost tracking. They're useful infrastructure - but they're not applications.

**What Liteskill does differently:**

- **It's a complete platform.** A proxy gateway has no UI, no conversation management, no persistence, and no user-facing experience. Liteskill is something your team can actually use.
- **Built-in provider management.** Liteskill handles multi-provider routing, circuit breaking, concurrency gating, and token-bucket rate limiting through its own LLM Gateway layer. A separate proxy in front is optional, not required.
- **No enterprise paywall for auth.** Proxy gateways commonly gate SSO, audit logs, and advanced RBAC behind paid tiers. Liteskill ships all authentication and authorization features in the open-source release.
- **Compatible, not competing.** If you already run a proxy gateway, Liteskill can use it as a provider - they complement each other.

---

## vs. Workflow Automation Platforms

Visual workflow builders let you connect triggers and actions into automated pipelines. Some have added AI nodes for LLM interactions. But AI is a bolt-on capability, not the core architecture.

**What Liteskill does differently:**

- **Purpose-built for AI conversations.** Streaming token-by-token responses, tool calling during generation, conversation forking, and message editing are all first-class features - not nodes wired into a generic workflow DAG.
- **Event-sourced state.** Workflow engines store execution history as flat records. Liteskill captures every conversation state change as an immutable event, enabling replay, auditing, and stream recovery.
- **Open tool protocol.** Workflow platforms typically connect to services through proprietary node/connector systems. Liteskill uses the open MCP protocol - any compliant tool server works without writing platform-specific integration code.
- **Apache 2.0 licensing.** Some workflow platforms use restrictive licenses that prohibit commercial embedding or redistribution. Liteskill is Apache 2.0 - use it however you want.
- **SSO and RBAC included.** No paid enterprise plan required for OIDC SSO, RBAC, or entity-level access controls.

---

## vs. Wiki & Knowledge Platforms

Wiki platforms excel at structured documentation with hierarchical content, collaborative editing, and content-level permissions. Some have mature SSO support. But they're static knowledge bases.

**What Liteskill does differently:**

- **AI-native knowledge.** Liteskill's built-in wiki isn't just a documentation tool - it's automatically synced to the RAG pipeline, so your documentation becomes searchable context for AI conversations. Knowledge isn't static; it's active.
- **Wiki is one feature, not the product.** Conversations, agents, reports, MCP tools, RAG, and the wiki all live in the same platform under the same unified access control system.
- **Event-sourced audit trail.** Traditional wikis use mutable ORM persistence. Liteskill's append-only event store provides an immutable record of every state change across the entire platform.

---

## vs. Agent Frameworks

Agent frameworks provide libraries and abstractions for building multi-agent AI systems in code. Agents have roles, goals, and tools. Some support MCP. But they're developer tools, not deployed applications.

**What Liteskill does differently:**

- **It's a platform, not a library.** Agent frameworks require you to build an application around them - writing your own UI, user management, persistence layer, and deployment infrastructure. Liteskill is a deployed application with a full web interface, real-time streaming, user accounts, and persistent conversation history.
- **Integrated chat + agents.** Agents and teams are defined through the Agent Studio UI, then invoked within the same platform where conversations happen. No separate application to build and maintain.
- **Enterprise auth built in.** Most agent frameworks have no auth, no RBAC, and no SSO in their open-source releases. Enterprise tiers that add these features often come with execution quotas and significant cost. Liteskill includes OIDC SSO, RBAC, entity ACLs, and group-based authorization in the open-source release with no quotas.
- **Event-sourced execution tracking.** Agent runs are tracked with structured logs, usage metrics, cost limits, and full event histories - not just basic logging.
- **Elixir's concurrency model.** Liteskill runs on the BEAM VM with lightweight processes, preemptive scheduling, and fault-tolerant supervision trees. Parallel agent topologies, concurrent tool calls, and streaming responses all benefit from these concurrency primitives without thread-safety complexity.

---

## What Liteskill Brings Together

| Capability | Chat UIs | LLM Proxies | Workflow Engines | Wiki Platforms | Agent Frameworks | **Liteskill** |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| LLM Chat UI | Yes | - | - | - | - | **Yes** |
| Event Sourcing | - | - | - | - | - | **Yes** |
| Conversation ACLs | - | - | - | - | - | **Yes** |
| RBAC (open source) | Basic | Paid | Paid | Some | Paid | **Yes** |
| OIDC SSO (open source) | Some | Paid | Paid | - | Paid | **Yes** |
| Native MCP Tools | - | - | - | - | Some | **Yes** |
| Agent Orchestration | - | - | Basic | - | Yes | **Yes** |
| RAG Pipeline | Some | - | - | - | - | **Yes** |
| Built-in Wiki | - | - | - | Yes | - | **Yes** |
| Structured Reports | - | - | - | - | - | **Yes** |
| Conversation Forking | - | - | - | - | - | **Yes** |
| Encryption at Rest | - | - | - | - | - | **Yes** |
| Multi-Provider LLM | Yes | Yes | Via plugins | - | Yes | **56+** |
| Apache 2.0 License | Varies | Varies | Restrictive | Varies | Varies | **Yes** |

---

## The Bottom Line

Most tools in this space solve one slice of the problem. You get a chat interface, or a provider gateway, or a workflow engine, or a wiki, or an agent framework - then stitch them together yourself.

Liteskill combines all of these into a single, event-sourced platform with enterprise access controls. And it ships everything under Apache 2.0 with no feature paywalls, no branding requirements, and no execution quotas.

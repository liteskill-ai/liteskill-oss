# Conversations

Conversations are the core feature of Liteskill. Each conversation is an event-sourced stream that records every user message, LLM response, and tool call.

## Creating Conversations

Users create conversations from the main UI. Each conversation has:

- A **title** (auto-generated or user-set)
- A **model** selection (from configured LLM models)
- An optional **system prompt**
- An optional **LLM model** override

## Messaging

When a user sends a message:

1. A `UserMessageAdded` event is appended to the conversation stream
2. The LLM `StreamHandler` starts a streaming response
3. Chunks arrive as `AssistantChunkReceived` events
4. The stream completes with `AssistantStreamCompleted`

## Tool Calling

During streaming, the LLM may request tool calls:

- **Auto-confirm mode**: Tool calls execute automatically via MCP servers
- **Manual mode**: The UI pauses for user approval before executing each tool call

Tool calls are recorded as `ToolCallStarted` and `ToolCallCompleted` events.

## RAG Context

When RAG is configured, the user's message is embedded and searched against accessible collections. Relevant document chunks are included as context for the LLM. RAG sources are tracked per message for transparency.

## Forking

Conversations can be forked at any message position, creating a new independent conversation with the history up to that point. The fork creates a new event stream with copied events and remapped IDs.

## Editing Messages

Users can edit a previously sent message. This truncates the conversation at that message position and re-sends with the new content, effectively creating a new branch point.

## Sharing

Conversation access is controlled via ACLs:

- The creator is automatically the **owner**
- Owners can grant **manager** access to other users or groups
- Shared conversations appear in the recipient's conversation list

## Archiving

Conversations can be archived individually or in bulk. Archived conversations are hidden from the default list but retain their full event history.

## Stream Recovery

A periodic sweeper (`Liteskill.Chat.StreamRecovery`) detects conversations stuck in streaming state for more than 5 minutes and automatically recovers them by failing the stream. Additionally, the `StreamRegistry` monitors active streaming tasks and triggers immediate recovery if a task crashes.

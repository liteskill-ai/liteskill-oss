# Chat Context

`Liteskill.Chat` is the primary context for conversation management. It provides write and read APIs backed by event sourcing.

## Boundary

```elixir
use Boundary,
  top_level?: true,
  deps: [Liteskill.Aggregate, Liteskill.Authorization, Liteskill.EventStore, Liteskill.Rbac, Liteskill.LlmModels],
  exports: [Conversation, ConversationAggregate, Events, Message, MessageBuilder, MessageChunk, Projector, StreamRecovery, StreamRegistry, ToolCall]
```

## Write API

All write operations go through the event sourcing pipeline: command → aggregate → event store → projector.

| Function | Description |
|----------|-------------|
| `create_conversation(params)` | Creates a new conversation with RBAC check |
| `send_message(conversation_id, user_id, content, opts)` | Adds a user message |
| `fork_conversation(conversation_id, user_id, at_message_position)` | Forks at a message boundary |
| `archive_conversation(conversation_id, user_id)` | Archives a conversation |
| `update_title(conversation_id, user_id, title)` | Updates the title |
| `truncate_conversation(conversation_id, user_id, message_id)` | Truncates at a message |
| `edit_message(conversation_id, user_id, message_id, new_content, opts)` | Truncates then re-sends |

## Read API

Read operations query the projection tables directly.

| Function | Description |
|----------|-------------|
| `list_conversations(user_id, opts)` | Lists accessible conversations (paginated, searchable) |
| `count_conversations(user_id, opts)` | Counts accessible conversations |
| `get_conversation(id, user_id)` | Gets a conversation with messages |
| `list_messages(conversation_id, user_id, opts)` | Lists messages (paginated) |
| `get_conversation_tree(conversation_id, user_id)` | Gets fork tree |
| `replay_conversation(conversation_id, user_id)` | Replays aggregate state |

## ACL Management

Delegates to `Liteskill.Authorization`:

- `grant_conversation_access/4` — Grant user access (normalizes "member" to "manager")
- `revoke_conversation_access/3` — Revoke user access
- `leave_conversation/2` — User leaves a shared conversation
- `grant_group_access/4` — Grant group access

## Streaming

Streaming is initiated after a user message is sent. The `StreamHandler` (in `Liteskill.LLM`) manages the LLM streaming lifecycle, emitting events back to the conversation's event stream. The `Projector` updates projection tables as events arrive, and LiveView receives real-time updates via PubSub.

## Message Builder

`Liteskill.Chat.MessageBuilder` constructs the message history for LLM requests from the conversation's projected messages, including tool call results and RAG context.

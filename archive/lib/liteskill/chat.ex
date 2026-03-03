defmodule Liteskill.Chat do
  @moduledoc """
  The Chat context. Provides write and read APIs for conversations.

  Write path: Context -> Aggregate -> EventStore -> PubSub -> Projector
  Read path: Context -> Ecto queries on projection tables
  """

  use Boundary,
    top_level?: true,
    deps: [
      Liteskill.Aggregate,
      Liteskill.Authorization,
      Liteskill.EventStore,
      Liteskill.Rbac,
      Liteskill.LlmModels
    ],
    exports: [
      Conversation,
      ConversationAggregate,
      Events,
      Message,
      MessageBuilder,
      MessageChunk,
      Projector,
      StreamRecovery,
      ToolCall
    ]

  import Ecto.Query

  alias Liteskill.Aggregate.Loader
  alias Liteskill.Authorization
  alias Liteskill.Chat.Conversation
  alias Liteskill.Chat.ConversationAggregate
  alias Liteskill.Chat.Message
  alias Liteskill.Chat.MessageChunk
  alias Liteskill.Chat.Projector
  alias Liteskill.EventStore.Postgres, as: Store
  alias Liteskill.Repo

  require Logger

  @max_replay_events 10_000

  # --- Write API ---

  def create_conversation(params) do
    with :ok <-
           Liteskill.Rbac.authorize(params[:user_id] || params["user_id"], "conversations:create") do
      conversation_id = params[:conversation_id] || Ecto.UUID.generate()
      stream_id = "conversation-#{conversation_id}"

      {model_id, llm_model_id} =
        case params[:llm_model_id] do
          nil ->
            {params[:model_id], nil}

          llm_model_id ->
            user_id = params[:user_id] || params["user_id"]

            case Liteskill.LlmModels.get_model(llm_model_id, user_id) do
              {:ok, %{model_id: mid}} -> {mid, llm_model_id}
              {:error, _} -> {params[:model_id], nil}
            end
        end

      if params[:llm_model_id] && is_nil(model_id) do
        {:error, :no_model_configured}
      else
        do_create_conversation(conversation_id, stream_id, params, model_id, llm_model_id)
      end
    end
  end

  defp do_create_conversation(conversation_id, stream_id, params, model_id, llm_model_id) do
    command =
      {:create_conversation,
       %{
         conversation_id: conversation_id,
         user_id: params[:user_id] || params["user_id"],
         title: params[:title] || "New Conversation",
         model_id: model_id,
         system_prompt: params[:system_prompt],
         llm_model_id: llm_model_id
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        conversation = Repo.one!(from c in Conversation, where: c.stream_id == ^stream_id)

        # Auto-create owner ACL in entity_acls
        {:ok, _} = Authorization.create_owner_acl("conversation", conversation.id, params[:user_id] || params["user_id"])

        {:ok, conversation}

      # coveralls-ignore-start — ConversationAggregate.handle_command(:create) always succeeds for fresh streams
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  def send_message(conversation_id, user_id, content, opts \\ []) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      message_id = Ecto.UUID.generate()
      tool_config = Keyword.get(opts, :tool_config)

      command =
        {:add_user_message, %{message_id: message_id, content: content, tool_config: tool_config}}

      execute_and_project(conversation.stream_id, command, fn ->
        {:ok, Repo.get!(Message, message_id)}
      end)
    end
  end

  def fork_conversation(conversation_id, user_id, at_message_position) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      parent_stream_id = conversation.stream_id

      # Read parent events up to the fork point (bounded to prevent OOM on huge conversations)
      parent_events = Store.read_stream_forward(parent_stream_id, 1, @max_replay_events)

      # Find the stream_version that corresponds to the message at the given position
      fork_at_version = find_version_at_position(parent_events, at_message_position)

      events_to_copy = Enum.filter(parent_events, &(&1.stream_version <= fork_at_version))

      # Create new stream
      new_conversation_id = Ecto.UUID.generate()
      new_stream_id = "conversation-#{new_conversation_id}"

      # Build fork event + copied events
      now = DateTime.to_iso8601(DateTime.utc_now())

      fork_event = %{
        event_type: "ConversationForked",
        data: %{
          "new_conversation_id" => new_conversation_id,
          "parent_stream_id" => parent_stream_id,
          "fork_at_version" => fork_at_version,
          "user_id" => user_id,
          "timestamp" => now
        }
      }

      {copied_events, _id_map} =
        Enum.map_reduce(events_to_copy, %{}, fn event, id_map ->
          {data, id_map} = remap_event_data(event, new_conversation_id, id_map)
          {%{event_type: event.event_type, data: data, metadata: event.metadata}, id_map}
        end)

      # ConversationCreated must come first so the projection exists
      # before ConversationForked tries to update it
      all_events = copied_events ++ [fork_event]

      case Store.append_events(new_stream_id, 0, all_events) do
        {:ok, stored_events} ->
          Projector.project_events(new_stream_id, stored_events)
          new_conv = Repo.one!(from c in Conversation, where: c.stream_id == ^new_stream_id)

          # Auto-create owner ACL for forked conversation
          {:ok, _} = Authorization.create_owner_acl("conversation", new_conv.id, user_id)

          {:ok, new_conv}

        # coveralls-ignore-start — Store.append_events fails only on UUID collision (:wrong_expected_version)
        {:error, reason} ->
          {:error, reason}
          # coveralls-ignore-stop
      end
    end
  end

  def archive_conversation(conversation_id, user_id) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      execute_and_project(conversation.stream_id, {:archive, %{}}, fn ->
        {:ok, Repo.get!(Conversation, conversation_id)}
      end)
    end
  end

  def update_title(conversation_id, user_id, title) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      execute_and_project(conversation.stream_id, {:update_title, %{title: title}}, fn ->
        {:ok, Repo.get!(Conversation, conversation_id)}
      end)
    end
  end

  def truncate_conversation(conversation_id, user_id, message_id) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      execute_and_project(
        conversation.stream_id,
        {:truncate_conversation, %{message_id: message_id}},
        fn -> {:ok, Repo.get!(Conversation, conversation_id)} end
      )
    end
  end

  # NOTE: This is two sequential aggregate commands (truncate + send). If the process
  # crashes between them, the conversation is left truncated without a replacement
  # message. This is acceptable: the user can re-send, and the event store preserves
  # the truncation event for auditability. A combined command would require changing
  # the aggregate protocol.
  def edit_message(conversation_id, user_id, message_id, new_content, opts \\ []) do
    with {:ok, _conversation} <- truncate_conversation(conversation_id, user_id, message_id) do
      send_message(conversation_id, user_id, new_content, opts)
    end
  end

  # --- ACL Management (delegates to Authorization) ---

  def grant_conversation_access(conversation_id, grantor_id, grantee_user_id, role \\ "member") do
    Authorization.grant_access(
      "conversation",
      conversation_id,
      grantor_id,
      grantee_user_id,
      Authorization.normalize_role(role)
    )
  end

  def revoke_conversation_access(conversation_id, revoker_id, target_user_id) do
    Authorization.revoke_access("conversation", conversation_id, revoker_id, target_user_id)
  end

  def leave_conversation(conversation_id, user_id) do
    Authorization.leave("conversation", conversation_id, user_id)
  end

  def grant_group_access(conversation_id, grantor_id, group_id, role \\ "member") do
    Authorization.grant_group_access(
      "conversation",
      conversation_id,
      grantor_id,
      group_id,
      Authorization.normalize_role(role)
    )
  end

  # --- Read API ---

  def list_conversations(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    user_id
    |> accessible_conversations_query(opts)
    |> order_by([c], desc: c.updated_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def count_conversations(user_id, opts \\ []) do
    user_id
    |> accessible_conversations_query(opts)
    |> Repo.aggregate(:count)
  end

  def bulk_archive_conversations([], _user_id), do: {:ok, 0}

  def bulk_archive_conversations(conversation_ids, user_id) do
    archived =
      Enum.count(conversation_ids, &match?({:ok, _}, archive_conversation(&1, user_id)))

    {:ok, archived}
  end

  def get_conversation(id, user_id) do
    case Repo.get(Conversation, id) do
      nil ->
        {:error, :not_found}

      conversation ->
        if has_access?(conversation, user_id) do
          {:ok,
           Repo.preload(conversation,
             messages: from(m in Message, order_by: [asc: m.position])
           )}
        else
          {:error, :not_found}
        end
    end
  end

  def list_messages(conversation_id, user_id, opts \\ []) do
    with {:ok, _conversation} <- authorize_conversation(conversation_id, user_id) do
      limit = Keyword.get(opts, :limit, 100)
      offset = Keyword.get(opts, :offset, 0)

      messages =
        Message
        |> where([m], m.conversation_id == ^conversation_id)
        |> order_by([m], asc: m.position)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()

      {:ok, messages}
    end
  end

  def update_message_rag_sources(message_id, user_id, rag_sources) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      msg ->
        with {:ok, _conv} <- authorize_conversation(msg.conversation_id, user_id) do
          msg |> Message.changeset(%{rag_sources: rag_sources}) |> Repo.update()
        end
    end
  end

  @doc """
  Deletes all message chunks for a given message.

  Called internally by StreamHandler to clean up orphaned chunks before
  retrying a failed stream.
  """
  def delete_message_chunks(message_id) do
    Repo.delete_all(from(c in MessageChunk, where: c.message_id == ^message_id))
  end

  def get_conversation_tree(conversation_id, user_id) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      root = find_root(conversation)

      descendants =
        {"tree", Conversation}
        |> recursive_ctes(true)
        |> with_cte("tree",
          as:
            fragment(
              """
              SELECT c.* FROM conversations c WHERE c.parent_conversation_id = ?
              UNION ALL
              SELECT c.* FROM conversations c
              INNER JOIN tree t ON c.parent_conversation_id = t.id
              """,
              type(^root.id, :binary_id)
            )
        )
        |> select([t], t)
        |> Repo.all()

      {:ok, [root | descendants]}
    end
  end

  def replay_conversation(conversation_id, user_id) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      {state, _version} = Loader.load(ConversationAggregate, conversation.stream_id)
      {:ok, state}
    end
  end

  def replay_from(conversation_id, user_id, from_version) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      events = Store.read_stream_forward(conversation.stream_id, from_version, @max_replay_events)

      state =
        Enum.reduce(events, ConversationAggregate.init(), fn event, acc ->
          ConversationAggregate.apply_event(acc, event)
        end)

      {:ok, state}
    end
  end

  @doc """
  Recovers a conversation stuck in streaming state by failing the streaming message.

  Returns `{:ok, conversation}` after recovery, or `{:ok, conversation}` if nothing
  needed recovering, or `{:error, reason}`.
  """
  def recover_stream(conversation_id, user_id) do
    with {:ok, conversation} <- authorize_conversation(conversation_id, user_id) do
      case do_recover_stream(
             conversation,
             "task_crashed",
             "Stream handler process terminated unexpectedly"
           ) do
        {:error, reason} -> {:error, reason}
        _ -> {:ok, Repo.get!(Conversation, conversation_id)}
      end
    end
  end

  @doc """
  Broadcasts a tool call decision (approve/reject) to the streaming process.
  """
  def broadcast_tool_decision(stream_id, tool_use_id, decision) when decision in [:approved, :rejected] do
    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "tool_approval:#{stream_id}",
      {:tool_decision, tool_use_id, decision}
    )
  end

  @doc """
  Returns conversations stuck in streaming status for longer than `threshold_minutes`.
  Used by the periodic sweeper to recover orphaned streams.
  """
  def list_stuck_streaming(threshold_minutes \\ 5) do
    cutoff = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

    Repo.all(
      from c in Conversation,
        where: c.status == "streaming" and c.updated_at < ^cutoff
    )
  end

  @doc false
  def recover_stream_by_id(conversation_id) do
    conversation = Repo.get!(Conversation, conversation_id)

    case do_recover_stream(
           conversation,
           "orphaned_stream",
           "Stream recovered by periodic sweep — no active handler"
         ) do
      {:error, reason} ->
        Logger.warning("Orphaned stream recovery failed: conversation=#{conversation_id} reason=#{inspect(reason)}")

        :error

      _ ->
        :ok
    end
  end

  # --- Internal Helpers ---

  defp do_recover_stream(conversation, error_type, error_message) do
    streaming_msg =
      Repo.one(
        from m in Message,
          where: m.conversation_id == ^conversation.id and m.status == "streaming",
          order_by: [desc: m.inserted_at],
          limit: 1
      )

    if streaming_msg do
      command =
        {:fail_stream,
         %{
           message_id: streaming_msg.id,
           error_type: error_type,
           error_message: error_message
         }}

      case Loader.execute(ConversationAggregate, conversation.stream_id, command) do
        {:ok, _state, events} ->
          Projector.project_events(conversation.stream_id, events)

        {:error, reason} ->
          Logger.warning("Stream recovery failed: stream=#{conversation.stream_id} reason=#{inspect(reason)}")

          {:error, reason}
      end
    else
      :ok
    end
  end

  defp execute_and_project(stream_id, command, on_success) do
    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        on_success.()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Returns :not_found for both missing and unauthorized conversations intentionally.
  # This prevents resource enumeration — callers cannot distinguish "does not exist"
  # from "exists but you lack access".
  defp authorize_conversation(conversation_id, user_id) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :not_found}

      conv ->
        if has_access?(conv, user_id) do
          {:ok, conv}
        else
          {:error, :not_found}
        end
    end
  end

  defp accessible_conversations_query(user_id, opts) do
    search = Keyword.get(opts, :search)
    accessible_ids = Authorization.accessible_entity_ids("conversation", user_id)

    query =
      Conversation
      |> where([c], c.user_id == ^user_id or c.id in subquery(accessible_ids))
      |> where([c], c.status != "archived")

    if search && search != "" do
      escaped =
        search
        |> String.replace("\\", "\\\\")
        |> String.replace("%", "\\%")
        |> String.replace("_", "\\_")

      term = "%#{escaped}%"
      where(query, [c], ilike(c.title, ^term))
    else
      query
    end
  end

  defp has_access?(conversation, user_id) do
    conversation.user_id == user_id or
      Authorization.has_access?("conversation", conversation.id, user_id)
  end

  defp find_version_at_position(events, position) do
    events
    |> Enum.reduce_while({0, 0}, fn event, {count, version} ->
      case event.event_type do
        type when type in ["UserMessageAdded", "AssistantStreamCompleted"] ->
          new_count = count + 1

          if new_count >= position do
            {:halt, {new_count, event.stream_version}}
          else
            {:cont, {new_count, event.stream_version}}
          end

        _ ->
          {:cont, {count, version}}
      end
    end)
    |> elem(1)
  end

  defp find_root(%Conversation{parent_conversation_id: nil} = conversation), do: conversation

  defp find_root(%Conversation{id: id}) do
    root_query =
      {"ancestors", Conversation}
      |> recursive_ctes(true)
      |> with_cte("ancestors",
        as:
          fragment(
            """
            SELECT c.* FROM conversations c WHERE c.id = ?
            UNION ALL
            SELECT p.* FROM conversations p
            INNER JOIN ancestors a ON a.parent_conversation_id = p.id
            """,
            type(^id, :binary_id)
          )
      )
      |> where([a], is_nil(a.parent_conversation_id))
      |> select([a], a.id)
      |> limit(1)

    root_id = Repo.one!(root_query)
    Repo.get!(Conversation, root_id)
  end

  defp remap_event_data(%{event_type: "ConversationCreated", data: data}, new_conv_id, id_map) do
    {Map.put(data, "conversation_id", new_conv_id), id_map}
  end

  defp remap_event_data(%{event_type: type, data: data}, _new_conv_id, id_map)
       when type in ["UserMessageAdded", "AssistantStreamStarted"] do
    old_id = data["message_id"]
    new_id = Ecto.UUID.generate()
    {Map.put(data, "message_id", new_id), Map.put(id_map, old_id, new_id)}
  end

  defp remap_event_data(%{event_type: type, data: data}, _new_conv_id, id_map)
       when type in ["AssistantChunkReceived", "AssistantStreamCompleted", "AssistantStreamFailed"] do
    {new_msg_id, id_map} = resolve_mapped_id(id_map, data["message_id"])
    {Map.put(data, "message_id", new_msg_id), id_map}
  end

  defp remap_event_data(%{event_type: type, data: data}, _new_conv_id, id_map)
       when type in ["ToolCallStarted", "ToolCallCompleted"] do
    {new_msg_id, id_map} = resolve_mapped_id(id_map, data["message_id"])

    {new_tool_use_id, id_map} =
      case Map.fetch(id_map, data["tool_use_id"]) do
        {:ok, existing} ->
          {existing, id_map}

        :error ->
          new_id = Ecto.UUID.generate()
          {new_id, Map.put(id_map, data["tool_use_id"], new_id)}
      end

    data =
      data
      |> Map.put("message_id", new_msg_id)
      |> Map.put("tool_use_id", new_tool_use_id)

    {data, id_map}
  end

  defp remap_event_data(%{event_type: "ConversationTruncated", data: data}, _new_conv_id, id_map) do
    {new_msg_id, id_map} = resolve_mapped_id(id_map, data["message_id"])
    {Map.put(data, "message_id", new_msg_id), id_map}
  end

  defp remap_event_data(%{data: data}, _new_conv_id, id_map) do
    {data, id_map}
  end

  # Resolves a mapped ID from the fork id_map. If the original_id isn't found
  # (shouldn't happen, but guards against malformed event data), generates a
  # fresh UUID and logs a warning instead of crashing the fork operation.
  defp resolve_mapped_id(id_map, original_id) do
    case Map.fetch(id_map, original_id) do
      {:ok, mapped_id} ->
        {mapped_id, id_map}

      # coveralls-ignore-start - defensive guard against malformed event data
      :error ->
        new_id = Ecto.UUID.generate()

        Logger.warning("Fork: unmapped ID #{inspect(original_id)}, generating replacement #{new_id}")

        {new_id, Map.put(id_map, original_id, new_id)}
        # coveralls-ignore-stop
    end
  end
end

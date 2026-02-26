defmodule LiteskillWeb.ConversationController do
  use LiteskillWeb, :controller

  alias Liteskill.Chat

  action_fallback LiteskillWeb.FallbackController

  def index(conn, params) do
    user = conn.assigns.current_user

    with {:ok, limit} <- parse_positive_integer(params["limit"], 20, 100),
         {:ok, offset} <- parse_positive_integer(params["offset"], 0, 10_000) do
      conversations = Chat.list_conversations(user.id, limit: limit, offset: offset)
      render(conn, :index, conversations: conversations)
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    conversation_params = %{
      user_id: user.id,
      title: Map.get(params, "title", "New Conversation"),
      model_id: Map.get(params, "model_id"),
      system_prompt: Map.get(params, "system_prompt")
    }

    case Chat.create_conversation(conversation_params) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> render(:create, conversation: conversation)

      # coveralls-ignore-start
      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "failed to create conversation"})

        # coveralls-ignore-stop
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, conversation} <- Chat.get_conversation(id, user.id) do
      render(conn, :show, conversation: conversation)
    end
  end

  def send_message(conn, %{"conversation_id" => conversation_id, "content" => content}) do
    user = conn.assigns.current_user

    case Chat.send_message(conversation_id, user.id, content) do
      {:ok, message} ->
        conn
        |> put_status(:created)
        |> render(:message, message: message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fork(conn, %{"conversation_id" => conversation_id} = params) do
    user = conn.assigns.current_user

    at_position =
      case Integer.parse(Map.get(params, "at_position", "1")) do
        {n, ""} when n > 0 ->
          n

        _ ->
          1
      end

    case Chat.fork_conversation(conversation_id, user.id, at_position) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> render(:fork, conversation: conversation)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def grant_access(conn, %{"conversation_id" => conversation_id} = params) do
    user = conn.assigns.current_user
    grantee_user_id = params["user_id"]
    role = Map.get(params, "role", "manager")

    case Chat.grant_conversation_access(conversation_id, user.id, grantee_user_id, role) do
      {:ok, acl} ->
        conn
        |> put_status(:created)
        |> json(%{data: %{id: acl.id, role: acl.role, user_id: acl.user_id}})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revoke_access(conn, %{
        "conversation_id" => conversation_id,
        "target_user_id" => target_user_id
      }) do
    user = conn.assigns.current_user

    case Chat.revoke_conversation_access(conversation_id, user.id, target_user_id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, reason} ->
        {:error, reason}
    end
  end

  def leave(conn, %{"conversation_id" => conversation_id}) do
    user = conn.assigns.current_user

    case Chat.leave_conversation(conversation_id, user.id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_positive_integer(nil, default, _max), do: {:ok, default}

  defp parse_positive_integer(value, default, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, min(n, max)}
      _ -> {:ok, default}
    end
  end
end

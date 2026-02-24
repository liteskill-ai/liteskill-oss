defmodule Liteskill.Rag.RequestLogger do
  @moduledoc false

  alias Liteskill.Rag.EmbeddingRequest
  alias Liteskill.Repo

  def log_request(nil, _attrs), do: :ok

  def log_request(user_id, attrs) do
    {status, error_message} =
      case attrs.result do
        {:ok, _} -> {"success", nil}
        {:error, %{status: s}} -> {"error", "HTTP #{s}"}
        # coveralls-ignore-next-line
        {:error, _} -> {"error", "request_failed"}
      end

    try do
      %EmbeddingRequest{}
      |> EmbeddingRequest.changeset(%{
        request_type: attrs.request_type,
        status: status,
        latency_ms: attrs.latency_ms,
        input_count: attrs.input_count,
        token_count: attrs.token_count,
        model_id: attrs.model_id,
        error_message: error_message,
        user_id: user_id
      })
      |> Repo.insert()
    rescue
      # coveralls-ignore-start
      _ ->
        :ok
        # coveralls-ignore-stop
    end
  end

  def estimate_token_count(texts) do
    texts
    |> Enum.map(fn text ->
      text |> String.split(~r/\s+/) |> length() |> Kernel.*(4) |> div(3)
    end)
    |> Enum.sum()
  end
end

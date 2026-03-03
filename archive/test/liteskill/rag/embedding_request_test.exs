defmodule Liteskill.Rag.EmbeddingRequestTest do
  use ExUnit.Case, async: true

  alias Liteskill.Rag.EmbeddingRequest

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        request_type: "embed",
        status: "success",
        user_id: Ecto.UUID.generate()
      }

      cs = EmbeddingRequest.changeset(%EmbeddingRequest{}, attrs)
      assert cs.valid?
    end

    test "valid changeset with all fields" do
      attrs = %{
        request_type: "rerank",
        status: "error",
        latency_ms: 150,
        input_count: 10,
        token_count: 500,
        model_id: "us.cohere.embed-v4:0",
        error_message: "HTTP 429",
        user_id: Ecto.UUID.generate()
      }

      cs = EmbeddingRequest.changeset(%EmbeddingRequest{}, attrs)
      assert cs.valid?
    end

    test "invalid without request_type" do
      attrs = %{status: "success", user_id: Ecto.UUID.generate()}
      cs = EmbeddingRequest.changeset(%EmbeddingRequest{}, attrs)
      refute cs.valid?
      assert errors_on(cs)[:request_type]
    end

    test "invalid without status" do
      attrs = %{request_type: "embed", user_id: Ecto.UUID.generate()}
      cs = EmbeddingRequest.changeset(%EmbeddingRequest{}, attrs)
      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "invalid without user_id" do
      attrs = %{request_type: "embed", status: "success"}
      cs = EmbeddingRequest.changeset(%EmbeddingRequest{}, attrs)
      refute cs.valid?
      assert errors_on(cs)[:user_id]
    end

    test "invalid request_type" do
      attrs = %{request_type: "invalid", status: "success", user_id: Ecto.UUID.generate()}
      cs = EmbeddingRequest.changeset(%EmbeddingRequest{}, attrs)
      refute cs.valid?
      assert errors_on(cs)[:request_type]
    end

    test "invalid status" do
      attrs = %{request_type: "embed", status: "pending", user_id: Ecto.UUID.generate()}
      cs = EmbeddingRequest.changeset(%EmbeddingRequest{}, attrs)
      refute cs.valid?
      assert errors_on(cs)[:status]
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

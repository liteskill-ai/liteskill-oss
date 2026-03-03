defmodule Liteskill.RagTestHelpers do
  @moduledoc """
  Shared helpers for RAG test modules.
  """

  alias Liteskill.Rag
  alias Liteskill.Rag.CohereClient

  def create_collection(user_id, attrs \\ %{}) do
    default = %{name: "Test Collection"}
    Rag.create_collection(Map.merge(default, attrs), user_id)
  end

  def create_source(collection_id, user_id, attrs \\ %{}) do
    default = %{name: "Test Source"}
    Rag.create_source(collection_id, Map.merge(default, attrs), user_id)
  end

  def create_document(source_id, user_id, attrs \\ %{}) do
    default = %{title: "Test Document"}
    Rag.create_document(source_id, Map.merge(default, attrs), user_id)
  end

  def stub_embed(embeddings) do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"embeddings" => %{"float" => embeddings}})
      )
    end)
  end

  def stub_rerank(results) do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"results" => results}))
    end)
  end

  def setup_users(_context) do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rag-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "rag-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rag-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other",
        oidc_sub: "rag-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner, other: other}
  end
end

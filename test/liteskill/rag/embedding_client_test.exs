defmodule Liteskill.Rag.EmbeddingClientTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Rag.EmbeddingClient
  alias Liteskill.Settings

  setup do
    Req.Test.set_req_test_to_shared()

    original_llm = Application.get_env(:liteskill, Liteskill.LLM, [])

    merged =
      Keyword.merge(original_llm,
        bedrock_bearer_token: "test-token",
        bedrock_region: "us-east-1"
      )

    Application.put_env(:liteskill, Liteskill.LLM, merged)

    # ReqLLM's validate_model calls prepare_request with empty opts, which
    # triggers api_key lookup. Provide a fallback so validation passes.
    original_openai_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, "test-key")

    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "embed-client-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "embed-client-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    on_exit(fn ->
      Application.put_env(:liteskill, Liteskill.LLM, original_llm)

      if original_openai_key,
        do: Application.put_env(:req_llm, :openai_api_key, original_openai_key),
        else: Application.delete_env(:req_llm, :openai_api_key)
    end)

    %{owner: owner}
  end

  describe "embed/2 with no configured model" do
    test "embeds via Bedrock Cohere fallback", %{owner: owner} do
      embedding = List.duplicate(0.1, 1024)

      Req.Test.stub(EmbeddingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
        )
      end)

      assert {:ok, [^embedding]} =
               EmbeddingClient.embed(
                 ["hello"],
                 input_type: "search_query",
                 user_id: owner.id,
                 plug: {Req.Test, EmbeddingClient}
               )
    end
  end

  describe "embed/2 with Bedrock provider" do
    setup %{owner: owner} do
      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Test Bedrock",
          provider_type: "amazon_bedrock",
          api_key: "bedrock-key",
          provider_config: %{"region" => "us-east-1"},
          user_id: owner.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "Cohere Embed",
          model_id: "us.cohere.embed-v4:0",
          model_type: "embedding",
          instance_wide: true,
          provider_id: provider.id,
          user_id: owner.id
        })

      Settings.get()
      {:ok, _} = Settings.update_embedding_model(model.id)

      %{provider: provider, model: model}
    end

    test "returns embeddings via ReqLLM", %{owner: owner} do
      embedding = List.duplicate(0.1, 1024)

      Req.Test.stub(EmbeddingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
        )
      end)

      assert {:ok, [^embedding]} =
               EmbeddingClient.embed(
                 ["hello"],
                 input_type: "search_query",
                 user_id: owner.id,
                 plug: {Req.Test, EmbeddingClient}
               )
    end
  end

  describe "embed/2 with OpenAI-compatible provider" do
    setup %{owner: owner} do
      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Test OpenRouter",
          provider_type: "openrouter",
          api_key: "openrouter-key",
          user_id: owner.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "Embedding 3 Small",
          model_id: "openai/text-embedding-3-small",
          model_type: "embedding",
          instance_wide: true,
          provider_id: provider.id,
          user_id: owner.id
        })

      Settings.get()
      {:ok, _} = Settings.update_embedding_model(model.id)

      %{provider: provider, model: model}
    end

    test "sends full model ID and dimensions in request body", %{owner: owner} do
      embedding = [0.1, 0.2, 0.3]

      Req.Test.stub(EmbeddingClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Full OpenRouter model ID preserved (not stripped to "text-embedding-3-small")
        assert decoded["model"] == "openai/text-embedding-3-small"
        assert decoded["input"] == ["hello"]
        assert decoded["dimensions"] == 1024

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => embedding}]})
        )
      end)

      assert {:ok, [^embedding]} =
               EmbeddingClient.embed(
                 ["hello"],
                 input_type: "search_query",
                 user_id: owner.id,
                 plug: {Req.Test, EmbeddingClient}
               )
    end

    test "returns error on API failure", %{owner: owner} do
      Req.Test.stub(EmbeddingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "server error"}))
      end)

      assert {:error, _} =
               EmbeddingClient.embed(
                 ["hello"],
                 input_type: "search_query",
                 user_id: owner.id,
                 plug: {Req.Test, EmbeddingClient}
               )
    end

    test "omits dimensions for models that do not support it", %{owner: owner} do
      # Reconfigure to use ada-002 (fixed 1536 dimensions, no dimensions param)
      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Test OpenRouter Ada",
          provider_type: "openrouter",
          api_key: "openrouter-key",
          user_id: owner.id
        })

      {:ok, ada_model} =
        Liteskill.LlmModels.create_model(%{
          name: "Embedding Ada",
          model_id: "openai/text-embedding-ada-002",
          model_type: "embedding",
          instance_wide: true,
          provider_id: provider.id,
          user_id: owner.id
        })

      {:ok, _} = Settings.update_embedding_model(ada_model.id)

      embedding = List.duplicate(0.1, 1536)

      Req.Test.stub(EmbeddingClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "openai/text-embedding-ada-002"
        refute Map.has_key?(decoded, "dimensions")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => embedding}]})
        )
      end)

      assert {:ok, [^embedding]} =
               EmbeddingClient.embed(
                 ["hello"],
                 input_type: "search_query",
                 user_id: owner.id,
                 plug: {Req.Test, EmbeddingClient}
               )
    end

    test "logs embedding request to DB", %{owner: owner} do
      embedding = [0.1, 0.2, 0.3]

      Req.Test.stub(EmbeddingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => embedding}]})
        )
      end)

      assert {:ok, _} =
               EmbeddingClient.embed(
                 ["hello world"],
                 input_type: "search_query",
                 user_id: owner.id,
                 plug: {Req.Test, EmbeddingClient}
               )

      request =
        Liteskill.Repo.one(
          from(r in Liteskill.Rag.EmbeddingRequest,
            where: r.user_id == ^owner.id,
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )

      assert request.request_type == "embed"
      assert request.status == "success"
      assert request.model_id == "openai/text-embedding-3-small"
      assert request.input_count == 1
    end
  end
end

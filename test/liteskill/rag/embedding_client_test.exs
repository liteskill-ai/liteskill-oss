defmodule Liteskill.Rag.EmbeddingClientTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Rag.{CohereClient, EmbeddingClient, OpenAIEmbeddingClient}
  alias Liteskill.Settings

  setup do
    Req.Test.set_req_test_to_shared()

    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "embed-client-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "embed-client-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner}
  end

  describe "embed/2 with no configured model" do
    test "delegates to CohereClient", %{owner: owner} do
      embedding = List.duplicate(0.1, 1024)

      Req.Test.stub(CohereClient, fn conn ->
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
                 plug: {Req.Test, CohereClient}
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

    test "delegates to CohereClient", %{owner: owner} do
      embedding = List.duplicate(0.1, 1024)

      Req.Test.stub(CohereClient, fn conn ->
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
                 plug: {Req.Test, CohereClient}
               )
    end

    test "remaps EmbeddingClient plug to CohereClient plug", %{owner: owner} do
      embedding = List.duplicate(0.1, 1024)

      Req.Test.stub(CohereClient, fn conn ->
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
          name: "Ada 002",
          model_id: "openai/text-embedding-ada-002",
          model_type: "embedding",
          instance_wide: true,
          provider_id: provider.id,
          user_id: owner.id
        })

      Settings.get()
      {:ok, _} = Settings.update_embedding_model(model.id)

      %{provider: provider, model: model}
    end

    test "delegates to OpenAIEmbeddingClient", %{owner: owner} do
      embedding = [0.1, 0.2, 0.3]

      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
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
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "remaps EmbeddingClient plug to OpenAIEmbeddingClient plug", %{owner: owner} do
      embedding = [0.1, 0.2, 0.3]

      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
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
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "server error"}))
      end)

      assert {:error, %{status: 500}} =
               EmbeddingClient.embed(
                 ["hello"],
                 input_type: "search_query",
                 user_id: owner.id,
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "logs embedding request to DB", %{owner: owner} do
      embedding = [0.1, 0.2, 0.3]

      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
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
                 plug: {Req.Test, OpenAIEmbeddingClient}
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
      assert request.model_id == "openai/text-embedding-ada-002"
      assert request.input_count == 1
    end

    test "uses default OpenRouter base URL", %{owner: owner} do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        assert conn.host == "openrouter.ai"
        assert conn.request_path == "/api/v1/embeddings"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => [0.1]}]})
        )
      end)

      assert {:ok, _} =
               EmbeddingClient.embed(
                 ["test"],
                 input_type: "search_query",
                 user_id: owner.id,
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end
  end
end

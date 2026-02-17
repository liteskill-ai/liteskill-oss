defmodule Liteskill.Rag.OpenAIEmbeddingClientTest do
  use ExUnit.Case, async: true

  alias Liteskill.Rag.OpenAIEmbeddingClient

  describe "embed/2" do
    test "returns embeddings sorted by index" do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"index" => 1, "embedding" => [0.2, 0.3]},
              %{"index" => 0, "embedding" => [0.1, 0.2]}
            ]
          })
        )
      end)

      assert {:ok, [[0.1, 0.2], [0.2, 0.3]]} =
               OpenAIEmbeddingClient.embed(
                 ["hello", "world"],
                 api_key: "test-key",
                 base_url: "https://api.example.com/v1",
                 model_id: "text-embedding-ada-002",
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "sends correct request body" do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "openai/text-embedding-ada-002"
        assert decoded["input"] == ["test text"]
        refute Map.has_key?(decoded, "dimensions")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => [0.1]}]})
        )
      end)

      assert {:ok, _} =
               OpenAIEmbeddingClient.embed(
                 ["test text"],
                 api_key: "test-key",
                 base_url: "https://api.example.com/v1",
                 model_id: "openai/text-embedding-ada-002",
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "includes dimensions for text-embedding-3 models" do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["dimensions"] == 256

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => [0.1]}]})
        )
      end)

      assert {:ok, _} =
               OpenAIEmbeddingClient.embed(
                 ["test"],
                 api_key: "test-key",
                 base_url: "https://api.example.com/v1",
                 model_id: "text-embedding-3-small",
                 dimensions: 256,
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "does not include dimensions for ada-002 even when provided" do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute Map.has_key?(decoded, "dimensions")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => [0.1]}]})
        )
      end)

      assert {:ok, _} =
               OpenAIEmbeddingClient.embed(
                 ["test"],
                 api_key: "test-key",
                 base_url: "https://api.example.com/v1",
                 model_id: "openai/text-embedding-ada-002",
                 dimensions: 1536,
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "returns error on non-200 status" do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"error" => "rate limited"}))
      end)

      assert {:error, %{status: 429}} =
               OpenAIEmbeddingClient.embed(
                 ["hello"],
                 api_key: "test-key",
                 base_url: "https://api.example.com/v1",
                 model_id: "text-embedding-ada-002",
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "sends authorization header" do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer my-secret-key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => [0.1]}]})
        )
      end)

      assert {:ok, _} =
               OpenAIEmbeddingClient.embed(
                 ["test"],
                 api_key: "my-secret-key",
                 base_url: "https://api.example.com/v1",
                 model_id: "test-model",
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "constructs correct URL from base_url" do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        assert conn.request_path == "/v1/embeddings"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => [0.1]}]})
        )
      end)

      assert {:ok, _} =
               OpenAIEmbeddingClient.embed(
                 ["test"],
                 api_key: "key",
                 base_url: "https://api.example.com/v1",
                 model_id: "model",
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end

    test "strips trailing slash from base_url" do
      Req.Test.stub(OpenAIEmbeddingClient, fn conn ->
        assert conn.request_path == "/v1/embeddings"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"index" => 0, "embedding" => [0.1]}]})
        )
      end)

      assert {:ok, _} =
               OpenAIEmbeddingClient.embed(
                 ["test"],
                 api_key: "key",
                 base_url: "https://api.example.com/v1/",
                 model_id: "model",
                 plug: {Req.Test, OpenAIEmbeddingClient}
               )
    end
  end
end

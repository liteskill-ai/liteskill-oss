defmodule Liteskill.OpenRouter.ModelsTest do
  use ExUnit.Case, async: true

  alias Liteskill.OpenRouter.Models

  describe "list_models/1" do
    test "returns parsed models on 200 success" do
      Req.Test.stub(Models, fn conn ->
        data = [
          %{
            "id" => "openai/gpt-4",
            "name" => "GPT-4",
            "context_length" => 8192,
            "pricing" => %{"prompt" => "0.00003", "completion" => "0.00006"},
            "architecture" => %{"modality" => "text->text"}
          },
          %{
            "id" => "anthropic/claude-3",
            "name" => "Claude 3",
            "context_length" => 200_000,
            "pricing" => %{"prompt" => "0.000003", "completion" => "0.000015"},
            "architecture" => %{"modality" => "text+image->text"}
          }
        ]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
      end)

      assert {:ok, models} = Models.list_models()
      assert length(models) == 2

      gpt4 = Enum.find(models, &(&1.id == "openai/gpt-4"))
      assert gpt4.name == "GPT-4"
      assert gpt4.context_length == 8192
      assert gpt4.model_type == "inference"
      assert %Decimal{} = gpt4.input_cost_per_million
    end

    test "returns error on non-200 status" do
      Req.Test.stub(Models, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => "unavailable"}))
      end)

      assert {:error, "OpenRouter returned status 503"} = Models.list_models()
    end

    test "returns error on transport failure" do
      Req.Test.stub(Models, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, "OpenRouter request failed: " <> _} = Models.list_models()
    end

    test "skips entries without id and name" do
      Req.Test.stub(Models, fn conn ->
        data = [
          %{"id" => "valid/model", "name" => "Valid"},
          %{"other" => "no-id-or-name"}
        ]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
      end)

      assert {:ok, models} = Models.list_models()
      assert length(models) == 1
    end
  end

  describe "list_embedding_models/1" do
    test "returns parsed models with model_type embedding on 200 success" do
      Req.Test.stub(Models, fn conn ->
        data = [
          %{
            "id" => "openai/text-embedding-3-small",
            "name" => "Text Embedding 3 Small",
            "context_length" => 8191,
            "pricing" => %{"prompt" => "0.00000002", "completion" => "0"},
            "architecture" => %{"modality" => "text->embedding"}
          },
          %{
            "id" => "cohere/embed-english-v3.0",
            "name" => "Cohere Embed English v3",
            "context_length" => 512,
            "pricing" => %{"prompt" => "0.0000001", "completion" => "0"},
            "architecture" => %{"modality" => "text->embedding"}
          }
        ]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
      end)

      assert {:ok, models} = Models.list_embedding_models()
      assert length(models) == 2

      for model <- models do
        assert model.model_type == "embedding"
      end

      small = Enum.find(models, &(&1.id == "openai/text-embedding-3-small"))
      assert small.name == "Text Embedding 3 Small"
      assert %Decimal{} = small.input_cost_per_million
    end

    test "returns error on non-200 status" do
      Req.Test.stub(Models, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"error" => "rate limited"}))
      end)

      assert {:error, "OpenRouter returned status 429"} = Models.list_embedding_models()
    end

    test "returns error on transport failure" do
      Req.Test.stub(Models, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      assert {:error, "OpenRouter request failed: " <> _} = Models.list_embedding_models()
    end

    test "handles numeric pricing values" do
      Req.Test.stub(Models, fn conn ->
        data = [
          %{
            "id" => "test/embed",
            "name" => "Test Embed",
            "context_length" => 512,
            "pricing" => %{"prompt" => 0.0000001, "completion" => 0}
          }
        ]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
      end)

      assert {:ok, [model]} = Models.list_embedding_models()
      assert model.model_type == "embedding"
      assert %Decimal{} = model.input_cost_per_million
    end

    test "handles unparseable and non-standard pricing values" do
      Req.Test.stub(Models, fn conn ->
        data = [
          %{
            "id" => "test/weird-pricing",
            "name" => "Weird Pricing",
            "context_length" => 512,
            "pricing" => %{"prompt" => "not-a-number", "completion" => true}
          }
        ]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
      end)

      assert {:ok, [model]} = Models.list_embedding_models()
      assert model.input_cost_per_million == nil
      assert model.output_cost_per_million == nil
    end
  end

  describe "search_models/3" do
    test "filters by name substring case-insensitive" do
      models = [
        %{id: "a/model", name: "Alpha"},
        %{id: "b/model", name: "Beta"},
        %{id: "c/model", name: "alpha-two"}
      ]

      results = Models.search_models(models, "alpha")
      assert length(results) == 2
    end

    test "respects limit" do
      models = Enum.map(1..20, &%{id: "m/#{&1}", name: "Model #{&1}"})
      results = Models.search_models(models, "model", 5)
      assert length(results) == 5
    end

    test "matches on id" do
      models = [%{id: "openai/gpt-4", name: "GPT Four"}]
      assert [_] = Models.search_models(models, "openai")
    end
  end
end

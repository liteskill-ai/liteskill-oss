defmodule Liteskill.EmbeddingCatalogTest do
  use ExUnit.Case, async: true

  alias Liteskill.EmbeddingCatalog
  alias Liteskill.OpenRouter.Models

  describe "list_models/0" do
    test "returns a non-empty list" do
      assert [_ | _] = EmbeddingCatalog.list_models()
    end

    test "all entries have required keys and model_type embedding" do
      for model <- EmbeddingCatalog.list_models() do
        assert is_binary(model.id)
        assert is_binary(model.name)
        assert model.model_type == "embedding"
        assert is_list(model.compatible_providers)
        assert [_ | _] = model.compatible_providers
        assert is_integer(model.dimensions)
      end
    end
  end

  describe "list_for_providers/1" do
    test "filters to openrouter-compatible models" do
      results = EmbeddingCatalog.list_for_providers(["openrouter"])
      assert [_ | _] = results

      for model <- results do
        assert "openrouter" in model.compatible_providers
      end
    end

    test "returns empty for unknown provider type" do
      assert EmbeddingCatalog.list_for_providers(["nonexistent_provider"]) == []
    end

    test "union of multiple provider types" do
      or_only = EmbeddingCatalog.list_for_providers(["openrouter"])
      google_only = EmbeddingCatalog.list_for_providers(["google"])
      combined = EmbeddingCatalog.list_for_providers(["openrouter", "google"])

      assert length(combined) >= length(or_only)
      assert length(combined) >= length(google_only)
    end
  end

  describe "filter_for_providers/2" do
    test "filters a dynamic model list by provider types" do
      models = [
        %{id: "a", compatible_providers: ["openrouter"]},
        %{id: "b", compatible_providers: ["openai"]},
        %{id: "c", compatible_providers: ["openrouter", "openai"]}
      ]

      result = EmbeddingCatalog.filter_for_providers(models, ["openai"])
      assert length(result) == 2
      assert Enum.all?(result, &("openai" in &1.compatible_providers))
    end

    test "defaults to openrouter when compatible_providers missing" do
      models = [%{id: "x"}]
      assert [_] = EmbeddingCatalog.filter_for_providers(models, ["openrouter"])
    end
  end

  describe "search/2" do
    test "matches by name substring case-insensitive" do
      results = EmbeddingCatalog.search("openai")
      assert [_ | _] = results
      assert Enum.all?(results, &String.contains?(String.downcase(&1.name), "openai"))
    end

    test "matches by id substring" do
      results = EmbeddingCatalog.search("text-embedding-3")
      assert [_ | _] = results
      assert Enum.all?(results, &String.contains?(&1.id, "text-embedding-3"))
    end

    test "returns empty for no match" do
      assert EmbeddingCatalog.search("zzz_no_such_model_zzz") == []
    end

    test "filters by provider types when given" do
      all_cohere = EmbeddingCatalog.search("cohere")
      or_cohere = EmbeddingCatalog.search("cohere", ["openrouter"])

      assert [_ | _] = all_cohere
      assert [_ | _] = or_cohere
      assert length(or_cohere) <= length(all_cohere)
    end
  end

  describe "search_models/2" do
    test "searches a given list of models" do
      models = [
        %{id: "openai/embed-small", name: "OpenAI Small"},
        %{id: "cohere/embed-v3", name: "Cohere V3"},
        %{id: "google/embed-004", name: "Google Embed"}
      ]

      assert [match] = EmbeddingCatalog.search_models(models, "cohere")
      assert match.id == "cohere/embed-v3"
    end

    test "is case-insensitive" do
      models = [%{id: "openai/test", name: "OpenAI Test"}]
      assert [_] = EmbeddingCatalog.search_models(models, "OPENAI")
    end
  end

  describe "get_model/1" do
    test "returns model for known id" do
      model = EmbeddingCatalog.get_model("openai/text-embedding-3-small")
      assert model
      assert model.name == "OpenAI Text Embedding 3 Small"
    end

    test "returns nil for unknown id" do
      assert EmbeddingCatalog.get_model("nonexistent/model") == nil
    end
  end

  describe "resolve_provider/2" do
    test "returns {:ok, provider_id} when a matching provider exists" do
      model = EmbeddingCatalog.get_model("openai/text-embedding-3-small")
      providers = [%{provider_type: "openrouter", id: "prov-123"}]

      assert {:ok, "prov-123"} = EmbeddingCatalog.resolve_provider(model, providers)
    end

    test "returns :error when no provider matches" do
      model = EmbeddingCatalog.get_model("openai/text-embedding-3-small")
      providers = [%{provider_type: "amazon_bedrock", id: "prov-456"}]

      assert :error = EmbeddingCatalog.resolve_provider(model, providers)
    end

    test "respects preference order from compatible_providers" do
      model = EmbeddingCatalog.get_model("openai/text-embedding-3-small")

      providers = [
        %{provider_type: "openai", id: "openai-1"},
        %{provider_type: "openrouter", id: "or-1"}
      ]

      # "openrouter" is first in compatible_providers, so it should be preferred
      assert {:ok, "or-1"} = EmbeddingCatalog.resolve_provider(model, providers)
    end

    test "works with dynamic models missing compatible_providers" do
      model = %{id: "dynamic/model", name: "Dynamic"}
      providers = [%{provider_type: "openrouter", id: "or-1"}]

      assert {:ok, "or-1"} = EmbeddingCatalog.resolve_provider(model, providers)
    end
  end

  describe "fetch_models/0" do
    test "falls back to static catalog on API failure" do
      Req.Test.stub(Models, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "internal"}))
      end)

      models = EmbeddingCatalog.fetch_models()
      assert length(models) == length(EmbeddingCatalog.list_models())
    end

    test "returns enriched dynamic models on API success" do
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
            "id" => "new-provider/embed-model",
            "name" => "New Embed Model",
            "context_length" => 512,
            "pricing" => %{"prompt" => "0.00000010", "completion" => "0"},
            "architecture" => %{"modality" => "text->embedding"}
          }
        ]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
      end)

      models = EmbeddingCatalog.fetch_models()
      assert length(models) == 2

      # Known model gets enriched with static catalog data
      known = Enum.find(models, &(&1.id == "openai/text-embedding-3-small"))
      assert known.dimensions == 1536
      assert "openai" in known.compatible_providers

      # Unknown model gets openrouter-only providers and nil dimensions
      unknown = Enum.find(models, &(&1.id == "new-provider/embed-model"))
      assert unknown.dimensions == nil
      assert unknown.compatible_providers == ["openrouter"]
    end
  end
end

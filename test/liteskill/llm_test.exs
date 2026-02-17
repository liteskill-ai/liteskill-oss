defmodule Liteskill.LLMTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.LLM
  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Usage.UsageRecord

  setup do
    Application.put_env(:liteskill, Liteskill.LLM, bedrock_region: "us-east-1")

    :ok
  end

  defp fake_response(text) do
    %ReqLLM.Response{
      id: "resp-1",
      model: "test",
      message: ReqLLM.Context.assistant(text),
      finish_reason: :stop,
      usage: %{input_tokens: 10, output_tokens: 5},
      context: ReqLLM.Context.new([])
    }
  end

  defp fake_generate(text) do
    fn _model, _context, _opts ->
      {:ok, fake_response(text)}
    end
  end

  describe "complete/2" do
    test "returns formatted response from ReqLLM" do
      messages = [%{role: :user, content: "Hello"}]

      assert {:ok,
              %{
                "output" => %{
                  "message" => %{"role" => "assistant", "content" => [%{"text" => "Hi there"}]}
                }
              }} =
               LLM.complete(messages,
                 model_id: "test-model",
                 generate_fn: fake_generate("Hi there")
               )
    end

    test "allows overriding model_id" do
      messages = [%{role: :user, content: "Hi"}]

      generate_fn = fn model, _context, _opts ->
        assert model == %{id: "custom-model", provider: :amazon_bedrock}
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} = LLM.complete(messages, model_id: "custom-model", generate_fn: generate_fn)
    end

    test "passes system prompt option" do
      messages = [%{role: :user, content: "Hi"}]

      generate_fn = fn _model, _context, opts ->
        assert Keyword.get(opts, :system_prompt) == "Be brief"
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} =
               LLM.complete(messages,
                 model_id: "test-model",
                 system: "Be brief",
                 generate_fn: generate_fn
               )
    end

    test "passes temperature and max_tokens" do
      messages = [%{role: :user, content: "Hi"}]

      generate_fn = fn _model, _context, opts ->
        assert Keyword.get(opts, :temperature) == 0.5
        assert Keyword.get(opts, :max_tokens) == 100
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} =
               LLM.complete(messages,
                 model_id: "test-model",
                 temperature: 0.5,
                 max_tokens: 100,
                 generate_fn: generate_fn
               )
    end

    test "returns error on failure" do
      messages = [%{role: :user, content: "Hello"}]

      generate_fn = fn _model, _context, _opts ->
        {:error, %{status: 500, body: "Internal error"}}
      end

      assert {:error, %{status: 500}} =
               LLM.complete(messages, model_id: "test-model", generate_fn: generate_fn)
    end
  end

  test "passes explicit provider_options through to generate_fn" do
    messages = [%{role: :user, content: "Hello"}]

    generate_fn = fn _model, _context, opts ->
      provider_opts = Keyword.get(opts, :provider_options, [])
      assert Keyword.get(provider_opts, :api_key) == "test-token"
      assert Keyword.get(provider_opts, :region) == "us-east-1"
      {:ok, fake_response("ok")}
    end

    assert {:ok, _} =
             LLM.complete(messages,
               model_id: "test-model",
               provider_options: [api_key: "test-token", region: "us-east-1"],
               generate_fn: generate_fn
             )
  end

  describe "complete/2 with llm_model" do
    test "uses llm_model for provider options when provided" do
      llm_model = %LlmModel{
        model_id: "claude-3-5-sonnet",
        provider: %LlmProvider{
          provider_type: "anthropic",
          api_key: "test-key",
          provider_config: %{}
        }
      }

      generate_fn = fn model, _context, opts ->
        assert model == %{id: "claude-3-5-sonnet", provider: :anthropic}
        assert Keyword.get(opts, :provider_options) == []
        assert Keyword.get(opts, :api_key) == "test-key"
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} =
               LLM.complete([%{role: :user, content: "Hi"}],
                 llm_model: llm_model,
                 generate_fn: generate_fn
               )
    end

    test "llm_model with amazon_bedrock includes region and use_converse" do
      llm_model = %LlmModel{
        model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
        provider: %LlmProvider{
          provider_type: "amazon_bedrock",
          api_key: "bedrock-token",
          provider_config: %{"region" => "us-west-2"}
        }
      }

      generate_fn = fn model, _context, opts ->
        assert model == %{
                 id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
                 provider: :amazon_bedrock
               }

        provider_opts = Keyword.get(opts, :provider_options)
        assert Keyword.get(provider_opts, :region) == "us-west-2"
        assert Keyword.get(provider_opts, :use_converse) == true
        assert Keyword.get(opts, :api_key) == "bedrock-token"
        {:ok, fake_response("ok")}
      end

      assert {:ok, _} =
               LLM.complete([%{role: :user, content: "Hi"}],
                 llm_model: llm_model,
                 generate_fn: generate_fn
               )
    end
  end

  test "raises when no model specified" do
    messages = [%{role: :user, content: "Hello"}]

    assert_raise RuntimeError, ~r/No model specified/, fn ->
      LLM.complete(messages, generate_fn: fn _, _, _ -> {:ok, fake_response("ok")} end)
    end
  end

  describe "usage recording in complete/2" do
    setup do
      {:ok, user} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "llm-usage-#{System.unique_integer([:positive])}@example.com",
          name: "LLM Usage Test",
          oidc_sub: "llm-usage-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      %{user: user}
    end

    test "records usage when user_id is provided", %{user: user} do
      messages = [%{role: :user, content: "Hello"}]

      assert {:ok, _} =
               LLM.complete(messages,
                 model_id: "test-model",
                 user_id: user.id,
                 generate_fn: fake_generate("Hi")
               )

      records = Repo.all(UsageRecord)
      assert length(records) == 1

      record = hd(records)
      assert record.user_id == user.id
      assert record.model_id == "test-model"
      assert record.call_type == "complete"
      assert record.input_tokens == 10
      assert record.output_tokens == 5
    end

    test "does not record usage when user_id is not provided" do
      messages = [%{role: :user, content: "Hello"}]

      assert {:ok, _} =
               LLM.complete(messages,
                 model_id: "test-model",
                 generate_fn: fake_generate("Hi")
               )

      assert Repo.all(UsageRecord) == []
    end

    test "does not record usage on error", %{user: user} do
      messages = [%{role: :user, content: "Hello"}]

      generate_fn = fn _model, _context, _opts ->
        {:error, %{status: 500, body: "fail"}}
      end

      assert {:error, _} =
               LLM.complete(messages,
                 model_id: "test-model",
                 user_id: user.id,
                 generate_fn: generate_fn
               )

      assert Repo.all(UsageRecord) == []
    end

    test "calculates costs from model rates when API returns no costs", %{user: user} do
      messages = [%{role: :user, content: "Hello"}]

      llm_model = %Liteskill.LlmModels.LlmModel{
        model_id: "claude-rated",
        input_cost_per_million: Decimal.new("3"),
        output_cost_per_million: Decimal.new("15"),
        provider: %Liteskill.LlmProviders.LlmProvider{
          provider_type: "anthropic",
          api_key: "test-key",
          provider_config: %{}
        }
      }

      generate_fn = fn _model, _context, _opts ->
        {:ok, fake_response("Hi")}
      end

      assert {:ok, _} =
               LLM.complete(messages,
                 model_id: "test-model",
                 user_id: user.id,
                 llm_model: llm_model,
                 generate_fn: generate_fn
               )

      records = Repo.all(UsageRecord)
      assert length(records) == 1

      record = hd(records)
      # 10 input tokens * 3 / 1M = 0.00003
      assert Decimal.equal?(record.input_cost, Decimal.new("0.00003"))
      # 5 output tokens * 15 / 1M = 0.000075
      assert Decimal.equal?(record.output_cost, Decimal.new("0.000075"))
      assert Decimal.equal?(record.total_cost, Decimal.new("0.000105"))
    end
  end
end

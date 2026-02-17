defmodule Liteskill.Agents.Actions.LlmGenerateTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Agents.Actions.LlmGenerate
  alias Liteskill.LlmProviders
  alias Liteskill.LlmModels

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "llmgen-#{System.unique_integer([:positive])}@example.com",
        name: "LLM Gen Owner",
        oidc_sub: "llmgen-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, provider} =
      LlmProviders.create_provider(%{
        name: "Test Provider #{System.unique_integer([:positive])}",
        provider_type: "anthropic",
        provider_config: %{},
        user_id: owner.id
      })

    {:ok, model} =
      LlmModels.create_model(%{
        name: "Test Model #{System.unique_integer([:positive])}",
        model_id: "claude-3-5-sonnet-20241022",
        provider_id: provider.id,
        user_id: owner.id
      })

    on_exit(fn ->
      Application.delete_env(:liteskill, :test_req_opts)
      Application.delete_env(:req_llm, :anthropic_api_key)
    end)

    %{owner: owner, model: model}
  end

  defp stub_llm_response(text) do
    Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      response = %{
        "id" => "msg_test_#{System.unique_integer([:positive])}",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => text}],
        "model" => "claude-3-5-sonnet-20241022",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)

    Application.put_env(:liteskill, :test_req_opts,
      req_http_options: [plug: {Req.Test, __MODULE__}]
    )

    Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")
  end

  defmodule FakeSearchLoop do
    def call_tool("fake_search", _input, _context) do
      {:ok, %{"content" => [%{"text" => "loop search result"}]}}
    end
  end

  defp make_context(state) do
    %{state: state}
  end

  describe "run/2 — no model" do
    test "returns error when no LLM model configured" do
      context =
        make_context(%{
          agent_name: "TestAgent",
          llm_model: nil,
          prompt: "hello"
        })

      assert {:error, msg} = LlmGenerate.run(%{}, context)
      assert msg =~ "No LLM model configured"
      assert msg =~ "TestAgent"
    end
  end

  describe "run/2 — successful generation" do
    test "generates text with basic prompt", %{model: model} do
      stub_llm_response("The answer is 42.")

      context =
        make_context(%{
          agent_name: "TestAgent",
          system_prompt: "You are helpful",
          backstory: "",
          opinions: %{},
          role: "analyst",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "What is the meaning of life?",
          prior_context: ""
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output == "The answer is 42."
      assert result.analysis =~ "TestAgent"
      assert result.analysis =~ "analyst"
      assert result.analysis =~ "direct"
      assert is_list(result.messages)
    end

    test "includes backstory and opinions in system prompt", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Verify system prompt contains backstory and opinions
        system = decoded["system"]

        assert is_binary(system) or is_list(system)

        system_text =
          if is_list(system) do
            Enum.map_join(system, " ", fn
              %{"text" => t} -> t
              s when is_binary(s) -> s
            end)
          else
            system
          end

        assert system_text =~ "Historical context"
        assert system_text =~ "key1"

        response = %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "Expert",
          system_prompt: "Be thorough",
          backstory: "Historical context",
          opinions: %{"key1" => "value1"},
          role: "researcher",
          strategy: "chain_of_thought",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "Research this",
          prior_context: ""
        })

      assert {:ok, _result} = LlmGenerate.run(%{}, context)
    end

    test "includes prior context in user message", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Check that the user message includes prior context
        messages = decoded["messages"] || []
        user_msg = Enum.find(messages, &(&1["role"] == "user"))

        if user_msg do
          content = user_msg["content"]

          text =
            cond do
              is_binary(content) -> content
              is_list(content) -> Enum.map_join(content, " ", &(&1["text"] || ""))
              true -> ""
            end

          assert text =~ "Previous stage handoffs"
          assert text =~ "Prior agent said something"
        end

        response = %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "Agent2",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "Do the thing",
          prior_context: "Prior agent said something"
        })

      assert {:ok, _result} = LlmGenerate.run(%{}, context)
    end
  end

  describe "run/2 — LLM error" do
    test "returns error when LLM call fails", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "internal error"}))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "FailAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "fail",
          prior_context: ""
        })

      assert {:error, %{reason: reason, messages: messages}} = LlmGenerate.run(%{}, context)
      assert reason =~ "LLM call failed"
      assert reason =~ "FailAgent"
      assert is_list(messages)
      assert length(messages) >= 2
      assert hd(messages)["role"] == "system"
    end
  end

  describe "run/2 — tool-calling loop" do
    test "executes tool calls and loops back to LLM", %{model: model} do
      {:ok, call_counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        call_num = Agent.get_and_update(call_counter, fn n -> {n, n + 1} end)

        response =
          if call_num == 0 do
            # First call: return a tool_use response
            %{
              "id" => "msg_tool",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Let me search."},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_123",
                  "name" => "fake_search",
                  "input" => %{"query" => "test"}
                }
              ],
              "model" => "claude-3-5-sonnet-20241022",
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 15}
            }
          else
            # Second call: return final text response
            %{
              "id" => "msg_final",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Found the answer: 42"}],
              "model" => "claude-3-5-sonnet-20241022",
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
            }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      defmodule FakeSearch do
        def call_tool("fake_search", %{"query" => "test"}, _context) do
          {:ok, %{"content" => [%{"text" => "search result: 42"}]}}
        end
      end

      tool_spec = %{
        "toolSpec" => %{
          "name" => "fake_search",
          "description" => "Search for things",
          "inputSchema" => %{"json" => %{"type" => "object"}}
        }
      }

      context =
        make_context(%{
          agent_name: "ToolAgent",
          system_prompt: "You can use tools",
          backstory: "",
          opinions: %{},
          role: "researcher",
          strategy: "react",
          llm_model: LlmModels.get_model!(model.id),
          tools: [tool_spec],
          tool_servers: %{"fake_search" => %{builtin: FakeSearch}},
          user_id: nil,
          prompt: "Find the answer",
          prior_context: ""
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output == "Found the answer: 42"
      assert Agent.get(call_counter, & &1) == 2

      Agent.stop(call_counter)
    end
  end

  describe "run/2 — retry on transient errors" do
    test "retries on 429 and succeeds on second attempt", %{model: model} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        call_num = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if call_num == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(429, Jason.encode!(%{"error" => "rate limited"}))
        else
          response = %{
            "id" => "msg_retry_ok",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "Retried successfully"}],
            "model" => "claude-3-5-sonnet-20241022",
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))
        end
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "RetryAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "test retry",
          prior_context: "",
          retry_opts: [backoff_ms: 1]
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output == "Retried successfully"
      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end

    test "fails after max retries on persistent 503", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => "unavailable"}))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "PersistentFailAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "fail forever",
          prior_context: "",
          retry_opts: [backoff_ms: 1]
        })

      assert {:error, %{reason: reason, messages: _}} = LlmGenerate.run(%{}, context)
      assert reason =~ "LLM call failed"
    end

    test "does not retry on non-retryable 400 error", %{model: model} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "bad request"}))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "NoRetryAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "bad input",
          prior_context: "",
          retry_opts: [backoff_ms: 1]
        })

      assert {:error, %{reason: _, messages: _}} = LlmGenerate.run(%{}, context)
      # Should only be called once — no retries
      assert Agent.get(counter, & &1) == 1
      Agent.stop(counter)
    end
  end

  describe "deserialize_context/1" do
    test "reconstructs system prompt and context from serialized messages" do
      messages = [
        %{"role" => "system", "content" => "You are helpful"},
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => "Hello"}],
          "tool_calls" => nil,
          "tool_call_id" => nil
        },
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Hi there"}],
          "tool_calls" => nil,
          "tool_call_id" => nil
        }
      ]

      {system_prompt, ctx} = LlmGenerate.deserialize_context(messages)
      assert system_prompt == "You are helpful"
      assert length(ctx.messages) == 2
      assert hd(ctx.messages).role == :user
      assert List.last(ctx.messages).role == :assistant
    end

    test "reconstructs tool call messages" do
      messages = [
        %{"role" => "system", "content" => "System"},
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => "Search for X"}],
          "tool_calls" => nil,
          "tool_call_id" => nil
        },
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Let me search"}],
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "search", "arguments" => "{\"q\":\"X\"}"}
            }
          ],
          "tool_call_id" => nil
        },
        %{
          "role" => "tool",
          "content" => [%{"type" => "text", "text" => "Found: result"}],
          "tool_calls" => nil,
          "tool_call_id" => "t1",
          "name" => "search"
        }
      ]

      {system_prompt, ctx} = LlmGenerate.deserialize_context(messages)
      assert system_prompt == "System"
      assert length(ctx.messages) == 3

      roles = Enum.map(ctx.messages, & &1.role)
      assert roles == [:user, :assistant, :tool]

      # Assistant has tool calls
      asst = Enum.at(ctx.messages, 1)
      assert length(asst.tool_calls) == 1

      # Tool result has correct tool_call_id
      tool = Enum.at(ctx.messages, 2)
      assert tool.tool_call_id == "t1"
    end

    test "handles string content (non-list)" do
      messages = [
        %{"role" => "system", "content" => "System"},
        %{"role" => "user", "content" => "plain text"}
      ]

      {_, ctx} = LlmGenerate.deserialize_context(messages)
      assert length(ctx.messages) == 1
    end

    test "handles system message with list content (ReqLLM format)" do
      # ReqLLM serializes system messages with list content blocks
      messages = [
        %{"role" => "system", "content" => "Our system prompt"},
        %{
          "role" => "system",
          "content" => [
            %{
              "type" => "text",
              "text" => "ReqLLM system message",
              "data" => nil,
              "filename" => nil,
              "media_type" => nil,
              "metadata" => %{},
              "url" => nil
            }
          ],
          "metadata" => %{},
          "name" => nil,
          "reasoning_details" => nil,
          "tool_call_id" => nil,
          "tool_calls" => nil
        },
        %{"role" => "user", "content" => "Hello"}
      ]

      {system_prompt, ctx} = LlmGenerate.deserialize_context(messages)
      assert system_prompt =~ "Our system prompt"
      assert system_prompt =~ "ReqLLM system message"
      assert length(ctx.messages) == 1
      assert hd(ctx.messages).role == :user
    end
  end

  describe "run/2 — resume from saved messages" do
    test "resumes from resume_messages instead of building fresh context", %{model: model} do
      # Build serialized messages as if from a previous crash
      resume_messages = [
        %{"role" => "system", "content" => "Custom system prompt from previous run"},
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => "Original prompt"}],
          "tool_calls" => nil,
          "tool_call_id" => nil
        },
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Partial response before crash"}],
          "tool_calls" => nil,
          "tool_call_id" => nil
        }
      ]

      # The LLM should see the resumed context (3 messages: user + assistant + new user continuation)
      # but ReqLLM just gets the existing context and continues from there
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Verify the messages include the prior context from resume
        messages = decoded["messages"] || []
        # Should have user + assistant from resume, not a fresh single user message
        assert length(messages) >= 2

        response = %{
          "id" => "msg_resume",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Continued from where we left off"}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 50, "output_tokens" => 20}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "ResumeAgent",
          system_prompt: "This should be ignored",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "This prompt should be ignored on resume",
          prior_context: "",
          resume_messages: resume_messages
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output == "Continued from where we left off"

      # The system message in the serialized output should be from the resume
      system_msg = Enum.find(result.messages, &(&1["role"] == "system"))
      assert system_msg["content"] == "Custom system prompt from previous run"
    end
  end

  describe "run/2 — handoff instruction" do
    test "includes handoff instruction when report_id is present", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        system = decoded["system"]

        system_text =
          if is_list(system) do
            Enum.map_join(system, " ", fn
              %{"text" => t} -> t
              s when is_binary(s) -> s
            end)
          else
            system
          end

        assert system_text =~ "Handoff Summary"
        assert system_text =~ "reports__get"
        assert system_text =~ "rpt_abc123"
        # Report dedup instruction
        assert system_text =~ "Do NOT create a new report"
        assert system_text =~ "reports__modify_sections"

        response = %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "HandoffAgent",
          system_prompt: "Be concise",
          backstory: "",
          opinions: %{},
          role: "analyst",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "Analyze this",
          prior_context: "",
          report_id: "rpt_abc123"
        })

      assert {:ok, _result} = LlmGenerate.run(%{}, context)
    end

    test "does not include handoff instruction when report_id is nil", %{model: model} do
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        system = decoded["system"]

        system_text =
          if is_list(system) do
            Enum.map_join(system, " ", fn
              %{"text" => t} -> t
              s when is_binary(s) -> s
            end)
          else
            system
          end

        refute system_text =~ "Handoff Summary"
        refute system_text =~ "reports__get"

        response = %{
          "id" => "msg_test",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      context =
        make_context(%{
          agent_name: "NoHandoffAgent",
          system_prompt: "Be concise",
          backstory: "",
          opinions: %{},
          role: "analyst",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "Analyze this",
          prior_context: ""
        })

      assert {:ok, _result} = LlmGenerate.run(%{}, context)
    end
  end

  describe "maybe_enable_prompt_cache/2" do
    test "enables caching when use_converse is false and ≤ 3 tools" do
      req_opts = [provider_options: [use_converse: false, region: "us-east-1"]]
      result = LlmGenerate.maybe_enable_prompt_cache(req_opts, 2)
      provider_opts = Keyword.get(result, :provider_options)

      assert Keyword.get(provider_opts, :anthropic_prompt_cache) == true
      assert Keyword.get(provider_opts, :anthropic_cache_messages) == -1
      assert Keyword.get(provider_opts, :use_converse) == false
    end

    test "does not enable caching when > 3 tools (exceeds Bedrock 4-block limit)" do
      req_opts = [provider_options: [use_converse: false]]
      result = LlmGenerate.maybe_enable_prompt_cache(req_opts, 8)
      provider_opts = Keyword.get(result, :provider_options)

      refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
    end

    test "does not enable caching when use_converse is not false" do
      req_opts = [provider_options: [use_converse: true]]
      result = LlmGenerate.maybe_enable_prompt_cache(req_opts, 0)
      provider_opts = Keyword.get(result, :provider_options)

      refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
    end

    test "does not enable caching when no provider_options" do
      req_opts = []
      result = LlmGenerate.maybe_enable_prompt_cache(req_opts, 0)
      assert result == []
    end

    test "enables caching with 0 tools (no tools)" do
      req_opts = [provider_options: [use_converse: false]]
      result = LlmGenerate.maybe_enable_prompt_cache(req_opts, 0)
      provider_opts = Keyword.get(result, :provider_options)

      assert Keyword.get(provider_opts, :anthropic_prompt_cache) == true
    end

    test "enables caching with exactly 3 tools (boundary)" do
      req_opts = [provider_options: [use_converse: false]]
      result = LlmGenerate.maybe_enable_prompt_cache(req_opts, 3)
      provider_opts = Keyword.get(result, :provider_options)

      assert Keyword.get(provider_opts, :anthropic_prompt_cache) == true
    end

    test "does not enable caching with 4 tools (boundary)" do
      req_opts = [provider_options: [use_converse: false]]
      result = LlmGenerate.maybe_enable_prompt_cache(req_opts, 4)
      provider_opts = Keyword.get(result, :provider_options)

      refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
    end
  end

  describe "build_system_prompt/1 — batch hints" do
    test "includes batch hint when tools are non-empty" do
      state = %{
        system_prompt: "Be helpful",
        role: "worker",
        backstory: "",
        opinions: %{},
        strategy: "direct",
        tools: [%{"toolSpec" => %{"name" => "wiki__write"}}]
      }

      prompt = LlmGenerate.build_system_prompt(state)
      assert prompt =~ "batching multiple operations"
      assert prompt =~ "wiki__write"
    end

    test "does not include batch hint when tools are empty" do
      state = %{
        system_prompt: "Be helpful",
        role: "worker",
        backstory: "",
        opinions: %{},
        strategy: "direct",
        tools: []
      }

      prompt = LlmGenerate.build_system_prompt(state)
      refute prompt =~ "batching"
    end
  end

  describe "build_system_prompt/1 — report dedup" do
    test "includes report dedup instruction when report_id is present" do
      state = %{
        system_prompt: "",
        role: "worker",
        backstory: "",
        opinions: %{},
        strategy: "direct",
        tools: [],
        report_id: "rpt_abc123"
      }

      prompt = LlmGenerate.build_system_prompt(state)
      assert prompt =~ "Do NOT create a new report"
      assert prompt =~ "reports__modify_sections"
      assert prompt =~ "rpt_abc123"
    end

    test "does not include report dedup when report_id is nil" do
      state = %{
        system_prompt: "",
        role: "worker",
        backstory: "",
        opinions: %{},
        strategy: "direct",
        tools: []
      }

      prompt = LlmGenerate.build_system_prompt(state)
      refute prompt =~ "Do NOT create a new report"
    end
  end

  describe "maybe_prune_context/2" do
    test "returns context unchanged when round < keep_rounds" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("hello")])
      assert LlmGenerate.maybe_prune_context(context, 0) == context
      assert LlmGenerate.maybe_prune_context(context, 3) == context
    end

    test "prunes old tool results when round >= keep_rounds" do
      # Build a context with 6 tool-calling rounds
      messages =
        Enum.flat_map(1..6, fn i ->
          [
            ReqLLM.Context.assistant("thinking round #{i}",
              tool_calls: [%{id: "t#{i}", name: "search", arguments: %{"q" => "r#{i}"}}]
            ),
            ReqLLM.Context.tool_result("t#{i}", "search", "result for round #{i}")
          ]
        end)

      messages = [ReqLLM.Context.user("hello") | messages]
      context = ReqLLM.Context.new(messages)

      pruned = LlmGenerate.maybe_prune_context(context, 5)

      # Count how many tool messages still have original content
      tool_messages = Enum.filter(pruned.messages, &(&1.role == :tool))
      assert length(tool_messages) == 6

      truncated =
        Enum.filter(tool_messages, fn m ->
          hd(m.content).text =~ "truncated"
        end)

      # With 6 rounds and keep_rounds=4, rounds 1-2 should be truncated
      assert length(truncated) == 2

      # Recent rounds (3-6) should still have original content
      recent =
        Enum.filter(tool_messages, fn m ->
          hd(m.content).text =~ "result for round"
        end)

      assert length(recent) == 4
    end

    test "preserves tool message structure (role, tool_call_id)" do
      messages = [
        ReqLLM.Context.user("hello"),
        ReqLLM.Context.assistant("thinking",
          tool_calls: [%{id: "t1", name: "search", arguments: %{}}]
        ),
        ReqLLM.Context.tool_result("t1", "search", "old result")
      ]

      context = ReqLLM.Context.new(messages)
      # With only 1 round and keep_rounds=4, nothing should be pruned
      pruned = LlmGenerate.prune_old_tool_results(context, 0)

      tool_msg = Enum.find(pruned.messages, &(&1.role == :tool))
      assert tool_msg.role == :tool
      assert tool_msg.tool_call_id == "t1"
      assert hd(tool_msg.content).text =~ "truncated"
    end

    test "returns context unchanged when cutoff_round <= 0" do
      messages = [
        ReqLLM.Context.user("hello"),
        ReqLLM.Context.assistant("reply")
      ]

      context = ReqLLM.Context.new(messages)
      assert LlmGenerate.prune_old_tool_results(context, 4) == context
    end
  end

  describe "run/2 — max iterations" do
    test "stops at max iterations with marker text", %{model: model} do
      # Stub that always returns tool calls (never a final text response)
      Req.Test.stub(Liteskill.Agents.Actions.LlmGenerateTest, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        response = %{
          "id" => "msg_loop_#{System.unique_integer([:positive])}",
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Let me search again."},
            %{
              "type" => "tool_use",
              "id" => "toolu_#{System.unique_integer([:positive])}",
              "name" => "fake_search",
              "input" => %{"query" => "loop"}
            }
          ],
          "model" => "claude-3-5-sonnet-20241022",
          "stop_reason" => "tool_use",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      Application.put_env(:liteskill, :test_req_opts,
        req_http_options: [plug: {Req.Test, __MODULE__}]
      )

      Application.put_env(:req_llm, :anthropic_api_key, "test-api-key")

      tool_spec = %{
        "toolSpec" => %{
          "name" => "fake_search",
          "description" => "Search",
          "inputSchema" => %{"json" => %{"type" => "object"}}
        }
      }

      context =
        make_context(%{
          agent_name: "LoopAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [tool_spec],
          tool_servers: %{
            "fake_search" => %{
              builtin: Liteskill.Agents.Actions.LlmGenerateTest.FakeSearchLoop
            }
          },
          user_id: nil,
          prompt: "loop test",
          prior_context: "",
          config: %{"max_iterations" => 2}
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output =~ "Max iterations (2) reached"
      assert result.output =~ "Let me search again."
    end
  end

  describe "run/2 — progress broadcasting" do
    test "broadcasts progress when run_id is set", %{model: model} do
      stub_llm_response("done")

      {:ok, owner} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "broadcast-#{System.unique_integer([:positive])}@example.com",
          name: "Broadcast User",
          oidc_sub: "broadcast-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Broadcast Test",
          prompt: "test",
          topology: "pipeline",
          user_id: owner.id
        })

      context =
        make_context(%{
          agent_name: "BroadcastAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: owner.id,
          prompt: "test broadcast",
          prior_context: "",
          run_id: run.id,
          log_fn: &Liteskill.Runs.add_log/5
        })

      assert {:ok, _result} = LlmGenerate.run(%{}, context)

      # Verify log was created
      {:ok, updated_run} = Liteskill.Runs.get_run(run.id, owner.id)
      llm_round_logs = Enum.filter(updated_run.run_logs, &(&1.step == "llm_round"))
      assert llm_round_logs != []

      log = hd(llm_round_logs)
      assert log.metadata["agent"] == "BroadcastAgent"
      assert log.metadata["round"] == 1
    end
  end

  describe "run/2 — strategy hints" do
    test "includes correct strategy hint for each strategy", %{model: model} do
      for {strategy, expected_fragment} <- [
            {"react", "Reason-Act"},
            {"chain_of_thought", "chain-of-thought"},
            {"tree_of_thoughts", "multiple approaches"},
            {"direct", "direct, focused"},
            {"custom_strat", "custom_strat approach"}
          ] do
        stub_llm_response("ok")

        context =
          make_context(%{
            agent_name: "StratAgent",
            system_prompt: "",
            backstory: "",
            opinions: %{},
            role: "worker",
            strategy: strategy,
            llm_model: LlmModels.get_model!(model.id),
            tools: [],
            tool_servers: %{},
            user_id: nil,
            prompt: "test",
            prior_context: ""
          })

        assert {:ok, result} = LlmGenerate.run(%{}, context)
        # The strategy is reflected in the analysis header
        assert result.analysis =~ strategy
        # The system prompt should contain the strategy hint (checked via messages)
        system_msg = Enum.find(result.messages, &(&1["role"] == "system"))
        assert system_msg["content"] =~ expected_fragment
      end
    end
  end

  describe "run/2 — cost limit" do
    test "stops when run cost exceeds limit", %{model: model} do
      stub_llm_response("first round")

      {:ok, owner} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "costlimit-#{System.unique_integer([:positive])}@example.com",
          name: "Cost Limit User",
          oidc_sub: "costlimit-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Cost Test",
          prompt: "test",
          topology: "pipeline",
          user_id: owner.id,
          cost_limit: Decimal.new("0.01")
        })

      # Record usage that exceeds the $0.01 limit
      Liteskill.Usage.record_usage(%{
        user_id: owner.id,
        run_id: run.id,
        model_id: "claude-3-5-sonnet-20241022",
        input_tokens: 1000,
        output_tokens: 500,
        total_tokens: 1500,
        input_cost: Decimal.new("0.50"),
        output_cost: Decimal.new("0.50"),
        total_cost: Decimal.new("1.00"),
        latency_ms: 100,
        call_type: "complete",
        tool_round: 0
      })

      context =
        make_context(%{
          agent_name: "CostAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: owner.id,
          prompt: "should not reach LLM",
          prior_context: "",
          run_id: run.id,
          cost_limit: Decimal.new("0.01")
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output =~ "Cost limit of $0.01 reached"
    end

    test "proceeds when cost is under limit", %{model: model} do
      stub_llm_response("completed successfully")

      {:ok, owner} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "costok-#{System.unique_integer([:positive])}@example.com",
          name: "Cost OK User",
          oidc_sub: "costok-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Cost OK Test",
          prompt: "test",
          topology: "pipeline",
          user_id: owner.id,
          cost_limit: Decimal.new("10.00")
        })

      context =
        make_context(%{
          agent_name: "CostOKAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: owner.id,
          prompt: "test",
          prior_context: "",
          run_id: run.id,
          cost_limit: Decimal.new("10.00")
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output == "completed successfully"
      refute result.output =~ "Cost limit"
    end

    test "skips cost check when cost_limit is nil", %{model: model} do
      stub_llm_response("no limit")

      context =
        make_context(%{
          agent_name: "NoLimitAgent",
          system_prompt: "",
          backstory: "",
          opinions: %{},
          role: "worker",
          strategy: "direct",
          llm_model: LlmModels.get_model!(model.id),
          tools: [],
          tool_servers: %{},
          user_id: nil,
          prompt: "test",
          prior_context: "",
          cost_limit: nil
        })

      assert {:ok, result} = LlmGenerate.run(%{}, context)
      assert result.output == "no limit"
    end
  end
end

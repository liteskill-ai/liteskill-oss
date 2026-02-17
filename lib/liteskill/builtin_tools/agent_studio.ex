defmodule Liteskill.BuiltinTools.AgentStudio do
  @moduledoc """
  Built-in tool suite for the Agent Studio.

  Exposes the full agent orchestration infrastructure (agents, teams, runs,
  schedules) as MCP tools so LLM agents can programmatically build and execute
  multi-agent workflows during a conversation.
  """

  @behaviour Liteskill.BuiltinTools

  alias Liteskill.Agents
  alias Liteskill.Teams
  alias Liteskill.Runs
  alias Liteskill.Runs.Runner
  alias Liteskill.Schedules

  @impl true
  def id, do: "agent_studio"

  @impl true
  def name, do: "Agent Studio"

  @impl true
  def description,
    do: "Create and manage AI agent workflows \u2014 agents, teams, runs, and schedules"

  # ---------------------------------------------------------------------------
  # Tool definitions
  # ---------------------------------------------------------------------------

  @impl true
  def list_tools do
    [
      # Discovery
      list_models_tool(),
      list_available_tools_tool(),
      # Agents
      create_agent_tool(),
      update_agent_tool(),
      list_agents_tool(),
      get_agent_tool(),
      delete_agent_tool(),
      # Teams
      create_team_tool(),
      update_team_tool(),
      list_teams_tool(),
      get_team_tool(),
      delete_team_tool(),
      # Runs
      start_run_tool(),
      list_runs_tool(),
      get_run_tool(),
      cancel_run_tool(),
      # Schedules
      create_schedule_tool(),
      list_schedules_tool(),
      delete_schedule_tool()
    ]
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  @impl true
  def call_tool(tool_name, input, context) do
    user_id = Keyword.fetch!(context, :user_id)
    dispatch(tool_name, user_id, input) |> wrap_result()
  end

  defp dispatch("agent_studio__list_models", user_id, _input), do: do_list_models(user_id)

  defp dispatch("agent_studio__list_available_tools", user_id, _input),
    do: do_list_available_tools(user_id)

  defp dispatch("agent_studio__create_agent", user_id, input), do: do_create_agent(user_id, input)
  defp dispatch("agent_studio__update_agent", user_id, input), do: do_update_agent(user_id, input)
  defp dispatch("agent_studio__list_agents", user_id, _input), do: do_list_agents(user_id)
  defp dispatch("agent_studio__get_agent", user_id, input), do: do_get_agent(user_id, input)
  defp dispatch("agent_studio__delete_agent", user_id, input), do: do_delete_agent(user_id, input)
  defp dispatch("agent_studio__create_team", user_id, input), do: do_create_team(user_id, input)
  defp dispatch("agent_studio__update_team", user_id, input), do: do_update_team(user_id, input)
  defp dispatch("agent_studio__list_teams", user_id, _input), do: do_list_teams(user_id)
  defp dispatch("agent_studio__get_team", user_id, input), do: do_get_team(user_id, input)
  defp dispatch("agent_studio__delete_team", user_id, input), do: do_delete_team(user_id, input)
  defp dispatch("agent_studio__start_run", user_id, input), do: do_start_run(user_id, input)
  defp dispatch("agent_studio__list_runs", user_id, _input), do: do_list_runs(user_id)
  defp dispatch("agent_studio__get_run", user_id, input), do: do_get_run(user_id, input)
  defp dispatch("agent_studio__cancel_run", user_id, input), do: do_cancel_run(user_id, input)

  defp dispatch("agent_studio__create_schedule", user_id, input),
    do: do_create_schedule(user_id, input)

  defp dispatch("agent_studio__list_schedules", user_id, _input),
    do: do_list_schedules(user_id)

  defp dispatch("agent_studio__delete_schedule", user_id, input),
    do: do_delete_schedule(user_id, input)

  defp dispatch(tool_name, _user_id, _input), do: {:error, "Unknown tool: #{tool_name}"}

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  defp do_list_models(user_id) do
    models = Liteskill.LLM.available_models(user_id)

    {:ok,
     %{
       "models" =>
         Enum.map(models, fn m ->
           %{
             "id" => m.id,
             "name" => m.name,
             "model_id" => m.model_id,
             "provider" => if(m.provider, do: m.provider.name, else: nil)
           }
         end)
     }}
  end

  defp do_list_available_tools(user_id) do
    servers = Liteskill.McpServers.list_servers(user_id)

    {:ok,
     %{
       "servers" =>
         Enum.map(servers, fn s ->
           base = %{
             "id" => s.id,
             "name" => s.name,
             "builtin" => is_map_key(s, :builtin) and s.builtin != nil
           }

           if is_map_key(s, :description) and s.description do
             Map.put(base, "description", s.description)
           else
             base
           end
         end)
     }}
  end

  # ---------------------------------------------------------------------------
  # Agents
  # ---------------------------------------------------------------------------

  defp do_create_agent(user_id, %{"name" => name} = input) do
    attrs = %{
      user_id: user_id,
      name: name,
      description: input["description"],
      system_prompt: input["system_prompt"],
      backstory: input["backstory"],
      opinions: input["opinions"] || %{},
      strategy: input["strategy"] || "react",
      llm_model_id: input["llm_model_id"],
      config: build_agent_config(input) || %{}
    }

    case Agents.create_agent(attrs) do
      {:ok, agent} ->
        tool_results = assign_agent_tools(agent.id, user_id, input["tools"] || [])
        {:ok, agent} = Agents.get_agent(agent.id, user_id)

        {:ok,
         %{
           "id" => agent.id,
           "name" => agent.name,
           "tools_assigned" => tool_results
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp do_create_agent(_user_id, _input), do: missing_field("name")

  defp do_update_agent(user_id, %{"agent_id" => agent_id} = input) do
    attrs =
      %{}
      |> maybe_put(:name, input["name"])
      |> maybe_put(:description, input["description"])
      |> maybe_put(:system_prompt, input["system_prompt"])
      |> maybe_put(:backstory, input["backstory"])
      |> maybe_put(:opinions, input["opinions"])
      |> maybe_put(:strategy, input["strategy"])
      |> maybe_put(:llm_model_id, input["llm_model_id"])
      |> maybe_put(:config, build_agent_config(input))

    case Agents.update_agent(agent_id, user_id, attrs) do
      {:ok, _agent} ->
        {:ok, agent} = Agents.get_agent(agent_id, user_id)
        {:ok, serialize_agent(agent)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_update_agent(_user_id, _input), do: missing_field("agent_id")

  defp do_list_agents(user_id) do
    agents = Agents.list_agents(user_id)

    {:ok,
     %{
       "agents" =>
         Enum.map(agents, fn a ->
           %{
             "id" => a.id,
             "name" => a.name,
             "description" => a.description,
             "strategy" => a.strategy,
             "model" => if(a.llm_model, do: a.llm_model.name, else: nil),
             "tool_count" => length(a.agent_tools)
           }
         end)
     }}
  end

  defp do_get_agent(user_id, %{"agent_id" => agent_id}) do
    case Agents.get_agent(agent_id, user_id) do
      {:ok, agent} ->
        {:ok, serialize_agent(agent)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_get_agent(_user_id, _input), do: missing_field("agent_id")

  defp do_delete_agent(user_id, %{"agent_id" => agent_id}) do
    case Agents.delete_agent(agent_id, user_id) do
      {:ok, _agent} -> {:ok, %{"deleted" => true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_delete_agent(_user_id, _input), do: missing_field("agent_id")

  # ---------------------------------------------------------------------------
  # Teams
  # ---------------------------------------------------------------------------

  defp do_create_team(user_id, %{"name" => name} = input) do
    attrs = %{
      user_id: user_id,
      name: name,
      description: input["description"],
      default_topology: input["topology"] || "pipeline",
      aggregation_strategy: input["aggregation_strategy"] || "last"
    }

    case Teams.create_team(attrs) do
      {:ok, team} ->
        member_results = assign_team_members(team.id, user_id, input["members"] || [])
        {:ok, team} = Teams.get_team(team.id, user_id)

        {:ok,
         %{
           "id" => team.id,
           "name" => team.name,
           "members_assigned" => member_results
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp do_create_team(_user_id, _input), do: missing_field("name")

  defp do_update_team(user_id, %{"team_id" => team_id} = input) do
    attrs =
      %{}
      |> maybe_put(:name, input["name"])
      |> maybe_put(:description, input["description"])
      |> maybe_put(:default_topology, input["topology"])
      |> maybe_put(:aggregation_strategy, input["aggregation_strategy"])

    case Teams.update_team(team_id, user_id, attrs) do
      {:ok, team} ->
        {:ok, serialize_team(team)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_update_team(_user_id, _input), do: missing_field("team_id")

  defp do_list_teams(user_id) do
    teams = Teams.list_teams(user_id)

    {:ok,
     %{
       "teams" =>
         Enum.map(teams, fn t ->
           %{
             "id" => t.id,
             "name" => t.name,
             "description" => t.description,
             "topology" => t.default_topology,
             "member_count" => length(t.team_members)
           }
         end)
     }}
  end

  defp do_get_team(user_id, %{"team_id" => team_id}) do
    case Teams.get_team(team_id, user_id) do
      {:ok, team} ->
        {:ok, serialize_team(team)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_get_team(_user_id, _input), do: missing_field("team_id")

  defp do_delete_team(user_id, %{"team_id" => team_id}) do
    case Teams.delete_team(team_id, user_id) do
      {:ok, _team} -> {:ok, %{"deleted" => true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_delete_team(_user_id, _input), do: missing_field("team_id")

  # ---------------------------------------------------------------------------
  # Runs
  # ---------------------------------------------------------------------------

  defp do_start_run(user_id, %{"prompt" => prompt} = input) do
    admin_max = Liteskill.Settings.get_default_mcp_run_cost_limit()

    cost_limit =
      case input["cost_limit"] do
        nil ->
          admin_max

        val when is_number(val) and val > 0 ->
          requested = Decimal.new("#{val}")
          if Decimal.compare(requested, admin_max) == :gt, do: admin_max, else: requested

        _non_positive ->
          admin_max
      end

    attrs = %{
      user_id: user_id,
      name: input["name"] || "Tool-initiated run",
      prompt: prompt,
      team_definition_id: input["team_id"],
      topology: input["topology"] || "pipeline",
      timeout_ms: input["timeout_ms"] || 3_600_000,
      cost_limit: cost_limit
    }

    case Runs.create_run(attrs) do
      {:ok, run} ->
        Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
          Runner.run(run.id, user_id)
        end)

        {:ok,
         %{
           "id" => run.id,
           "name" => run.name,
           "status" => run.status,
           "message" => "Run started. Use agent_studio__get_run to poll for status."
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp do_start_run(_user_id, _input), do: missing_field("prompt")

  defp do_list_runs(user_id) do
    runs = Runs.list_runs(user_id)

    {:ok,
     %{
       "runs" =>
         Enum.map(runs, fn r ->
           %{
             "id" => r.id,
             "name" => r.name,
             "status" => r.status,
             "started_at" => format_datetime(r.started_at),
             "completed_at" => format_datetime(r.completed_at),
             "deliverables" => r.deliverables
           }
         end)
     }}
  end

  defp do_get_run(user_id, %{"run_id" => run_id}) do
    case Runs.get_run(run_id, user_id) do
      {:ok, run} ->
        {:ok, serialize_run(run)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_get_run(_user_id, _input), do: missing_field("run_id")

  defp do_cancel_run(user_id, %{"run_id" => run_id}) do
    case Runs.cancel_run(run_id, user_id) do
      {:ok, run} -> {:ok, %{"id" => run.id, "status" => run.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_cancel_run(_user_id, _input), do: missing_field("run_id")

  # ---------------------------------------------------------------------------
  # Schedules
  # ---------------------------------------------------------------------------

  defp do_create_schedule(user_id, %{"cron_expression" => cron} = input) do
    attrs = %{
      user_id: user_id,
      name: input["name"] || "Tool-created schedule",
      cron_expression: cron,
      timezone: input["timezone"] || "UTC",
      prompt: input["prompt"] || "",
      team_definition_id: input["team_id"],
      topology: input["topology"] || "pipeline",
      timeout_ms: input["timeout_ms"] || 3_600_000,
      enabled: Map.get(input, "enabled", true)
    }

    case Schedules.create_schedule(attrs) do
      {:ok, schedule} ->
        {:ok,
         %{
           "id" => schedule.id,
           "name" => schedule.name,
           "cron_expression" => schedule.cron_expression,
           "timezone" => schedule.timezone,
           "enabled" => schedule.enabled,
           "next_run_at" => format_datetime(schedule.next_run_at)
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp do_create_schedule(_user_id, _input), do: missing_field("cron_expression")

  defp do_list_schedules(user_id) do
    schedules = Schedules.list_schedules(user_id)

    {:ok,
     %{
       "schedules" =>
         Enum.map(schedules, fn s ->
           %{
             "id" => s.id,
             "name" => s.name,
             "cron_expression" => s.cron_expression,
             "timezone" => s.timezone,
             "enabled" => s.enabled,
             "next_run_at" => format_datetime(s.next_run_at),
             "last_run_at" => format_datetime(s.last_run_at)
           }
         end)
     }}
  end

  defp do_delete_schedule(user_id, %{"schedule_id" => schedule_id}) do
    case Schedules.delete_schedule(schedule_id, user_id) do
      {:ok, _schedule} -> {:ok, %{"deleted" => true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_delete_schedule(_user_id, _input), do: missing_field("schedule_id")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp missing_field(name), do: {:error, "Missing required field: #{name}"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_agent_config(%{"builtin_server_ids" => ids}) when is_list(ids) do
    %{"builtin_server_ids" => ids}
  end

  defp build_agent_config(_input), do: nil

  defp assign_agent_tools(agent_id, user_id, tools) do
    {builtin_tools, mcp_tools} =
      Enum.split_with(tools, fn tool ->
        String.starts_with?(tool["server_id"] || "", "builtin:")
      end)

    builtin_results = assign_builtin_tools(agent_id, user_id, builtin_tools)

    mcp_results =
      Enum.map(mcp_tools, fn tool ->
        server_id = tool["server_id"]
        tool_name = tool["tool_name"]

        case Agents.add_tool(agent_id, server_id, tool_name, user_id) do
          {:ok, _at} ->
            %{"server_id" => server_id, "tool_name" => tool_name, "status" => "ok"}

          {:error, _} ->
            %{"server_id" => server_id, "tool_name" => tool_name, "status" => "failed"}
        end
      end)

    builtin_results ++ mcp_results
  end

  defp assign_builtin_tools(_agent_id, _user_id, []), do: []

  defp assign_builtin_tools(agent_id, user_id, builtin_tools) do
    builtin_ids = Enum.map(builtin_tools, & &1["server_id"]) |> Enum.uniq()

    case Agents.get_agent(agent_id, user_id) do
      {:ok, agent} ->
        existing = get_in(agent.config, ["builtin_server_ids"]) || []
        merged = Enum.uniq(existing ++ builtin_ids)
        config = Map.put(agent.config || %{}, "builtin_server_ids", merged)

        case Agents.update_agent(agent_id, user_id, %{config: config}) do
          {:ok, _} ->
            Enum.map(builtin_tools, fn tool ->
              %{
                "server_id" => tool["server_id"],
                "tool_name" => tool["tool_name"],
                "status" => "ok"
              }
            end)

          # coveralls-ignore-start
          {:error, _} ->
            Enum.map(builtin_tools, fn tool ->
              %{
                "server_id" => tool["server_id"],
                "tool_name" => tool["tool_name"],
                "status" => "failed"
              }
            end)

            # coveralls-ignore-stop
        end

      # coveralls-ignore-start
      {:error, _} ->
        Enum.map(builtin_tools, fn tool ->
          %{
            "server_id" => tool["server_id"],
            "tool_name" => tool["tool_name"],
            "status" => "failed"
          }
        end)

        # coveralls-ignore-stop
    end
  end

  defp assign_team_members(team_id, user_id, members) do
    members
    |> Enum.with_index()
    |> Enum.map(fn {member, idx} ->
      agent_id = member["agent_id"]

      attrs = %{
        role: member["role"] || "worker",
        description: member["description"],
        position: idx
      }

      case Teams.add_member(team_id, agent_id, user_id, attrs) do
        {:ok, _tm} -> %{"agent_id" => agent_id, "position" => idx, "status" => "ok"}
        {:error, _} -> %{"agent_id" => agent_id, "position" => idx, "status" => "failed"}
      end
    end)
  end

  defp serialize_agent(agent) do
    %{
      "id" => agent.id,
      "name" => agent.name,
      "description" => agent.description,
      "system_prompt" => agent.system_prompt,
      "backstory" => agent.backstory,
      "strategy" => agent.strategy,
      "model" =>
        if agent.llm_model do
          %{
            "id" => agent.llm_model.id,
            "name" => agent.llm_model.name,
            "provider" =>
              if(agent.llm_model.provider, do: agent.llm_model.provider.name, else: nil)
          }
        end,
      "tools" =>
        Enum.map(agent.agent_tools, fn at ->
          %{
            "server_id" => at.mcp_server_id,
            "server_name" => if(at.mcp_server, do: at.mcp_server.name, else: nil),
            "tool_name" => at.tool_name
          }
        end),
      "config" => agent.config
    }
  end

  defp serialize_team(team) do
    %{
      "id" => team.id,
      "name" => team.name,
      "description" => team.description,
      "topology" => team.default_topology,
      "aggregation_strategy" => team.aggregation_strategy,
      "members" =>
        Enum.map(team.team_members, fn tm ->
          %{
            "agent_id" => tm.agent_definition_id,
            "agent_name" => if(tm.agent_definition, do: tm.agent_definition.name, else: nil),
            "role" => tm.role,
            "description" => tm.description,
            "position" => tm.position
          }
        end)
    }
  end

  defp serialize_run(run) do
    %{
      "id" => run.id,
      "name" => run.name,
      "status" => run.status,
      "prompt" => run.prompt,
      "topology" => run.topology,
      "started_at" => format_datetime(run.started_at),
      "completed_at" => format_datetime(run.completed_at),
      "deliverables" => run.deliverables,
      "error" => run.error,
      "tasks" =>
        Enum.map(run.run_tasks, fn t ->
          %{
            "id" => t.id,
            "name" => t.name,
            "status" => t.status,
            "duration_ms" => t.duration_ms
          }
        end),
      "log_count" => length(run.run_logs)
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(dt), do: DateTime.to_iso8601(dt)

  defp format_changeset(%Ecto.Changeset{} = cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          # coveralls-ignore-next-line
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    "Validation failed: #{inspect(errors)}"
  end

  # ---------------------------------------------------------------------------
  # Result wrapper (same contract as Reports / Wiki)
  # ---------------------------------------------------------------------------

  # coveralls-ignore-start
  defp wrap_result({:ok, data}) when is_binary(data) do
    {:ok, %{"content" => [%{"type" => "text", "text" => data}]}}
  end

  # coveralls-ignore-stop

  defp wrap_result({:ok, data}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(data)}]}}
  end

  defp wrap_result({:error, reason}) do
    text =
      case reason do
        atom when is_atom(atom) -> Atom.to_string(atom)
        str when is_binary(str) -> str
        # coveralls-ignore-next-line
        _ -> "unknown error"
      end

    {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(%{"error" => text})}]}}
  end

  # ---------------------------------------------------------------------------
  # Tool specs
  # ---------------------------------------------------------------------------

  defp list_models_tool do
    %{
      "name" => "agent_studio__list_models",
      "description" => "List available LLM models. Returns model IDs needed for creating agents.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{}
      }
    }
  end

  defp list_available_tools_tool do
    %{
      "name" => "agent_studio__list_available_tools",
      "description" =>
        "List available MCP servers and built-in tool suites. " <>
          "Returns server IDs needed for assigning tools to agents.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{}
      }
    }
  end

  defp create_agent_tool do
    %{
      "name" => "agent_studio__create_agent",
      "description" =>
        "Create an AI agent definition with optional inline tool assignment. " <>
          "Use agent_studio__list_models first to get a valid llm_model_id. " <>
          "Use agent_studio__list_available_tools to get server IDs for the tools array.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Agent name (unique per user)"},
          "description" => %{
            "type" => "string",
            "description" => "Short description of the agent's purpose"
          },
          "system_prompt" => %{
            "type" => "string",
            "description" => "System prompt for the agent"
          },
          "backstory" => %{
            "type" => "string",
            "description" => "Backstory / persona for the agent"
          },
          "opinions" => %{
            "type" => "object",
            "description" => "Key-value pairs of agent opinions / preferences"
          },
          "strategy" => %{
            "type" => "string",
            "enum" => ["react", "chain_of_thought", "tree_of_thoughts", "direct"],
            "description" => "Reasoning strategy (default: react)"
          },
          "llm_model_id" => %{
            "type" => "string",
            "description" => "UUID of the LLM model to use (from list_models)"
          },
          "tools" => %{
            "type" => "array",
            "description" => "Tools to assign to the agent",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "server_id" => %{
                  "type" => "string",
                  "description" => "MCP server UUID or builtin server ID"
                },
                "tool_name" => %{
                  "type" => "string",
                  "description" =>
                    "Specific tool name from the server (omit to include all tools from server)"
                }
              },
              "required" => ["server_id"]
            }
          },
          "builtin_server_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Built-in server IDs to enable (e.g. [\"builtin:reports\", \"builtin:wiki\"])"
          }
        },
        "required" => ["name"]
      }
    }
  end

  defp update_agent_tool do
    %{
      "name" => "agent_studio__update_agent",
      "description" =>
        "Update an existing agent definition. Only include fields you want to change. " <>
          "Use agent_studio__list_models to get valid llm_model_id values.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{"type" => "string", "description" => "Agent UUID to update"},
          "name" => %{"type" => "string", "description" => "New agent name"},
          "description" => %{"type" => "string", "description" => "New description"},
          "system_prompt" => %{"type" => "string", "description" => "New system prompt"},
          "backstory" => %{"type" => "string", "description" => "New backstory"},
          "opinions" => %{
            "type" => "object",
            "description" => "New opinions key-value pairs"
          },
          "strategy" => %{
            "type" => "string",
            "enum" => ["react", "chain_of_thought", "tree_of_thoughts", "direct"],
            "description" => "New reasoning strategy"
          },
          "llm_model_id" => %{
            "type" => "string",
            "description" => "UUID of the LLM model to use (from list_models)"
          },
          "builtin_server_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Built-in server IDs to enable"
          }
        },
        "required" => ["agent_id"]
      }
    }
  end

  defp list_agents_tool do
    %{
      "name" => "agent_studio__list_agents",
      "description" => "List all accessible agent definitions with summary info.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{}
      }
    }
  end

  defp get_agent_tool do
    %{
      "name" => "agent_studio__get_agent",
      "description" => "Get full details of an agent definition by ID.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{"type" => "string", "description" => "Agent UUID"}
        },
        "required" => ["agent_id"]
      }
    }
  end

  defp delete_agent_tool do
    %{
      "name" => "agent_studio__delete_agent",
      "description" => "Delete an agent definition. Only the owner can delete.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{"type" => "string", "description" => "Agent UUID"}
        },
        "required" => ["agent_id"]
      }
    }
  end

  defp create_team_tool do
    %{
      "name" => "agent_studio__create_team",
      "description" =>
        "Create a team with optional inline member assignment. " <>
          "Members are added in the order provided (position 0, 1, 2...).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Team name (unique per user)"},
          "description" => %{
            "type" => "string",
            "description" => "Description of the team's purpose"
          },
          "topology" => %{
            "type" => "string",
            "enum" => ["pipeline", "parallel", "debate", "hierarchical", "round_robin"],
            "description" => "Execution topology (default: pipeline)"
          },
          "aggregation_strategy" => %{
            "type" => "string",
            "enum" => ["last", "merge", "vote"],
            "description" => "How to aggregate member outputs (default: last)"
          },
          "members" => %{
            "type" => "array",
            "description" => "Team members in execution order",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "agent_id" => %{
                  "type" => "string",
                  "description" => "Agent UUID (from create_agent or list_agents)"
                },
                "role" => %{
                  "type" => "string",
                  "description" => "Member role (default: worker)"
                },
                "description" => %{
                  "type" => "string",
                  "description" => "Description of this member's responsibility"
                }
              },
              "required" => ["agent_id"]
            }
          }
        },
        "required" => ["name"]
      }
    }
  end

  defp update_team_tool do
    %{
      "name" => "agent_studio__update_team",
      "description" =>
        "Update an existing team definition. Only include fields you want to change.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "team_id" => %{"type" => "string", "description" => "Team UUID to update"},
          "name" => %{"type" => "string", "description" => "New team name"},
          "description" => %{"type" => "string", "description" => "New description"},
          "topology" => %{
            "type" => "string",
            "enum" => ["pipeline", "parallel", "debate", "hierarchical", "round_robin"],
            "description" => "New execution topology"
          },
          "aggregation_strategy" => %{
            "type" => "string",
            "enum" => ["last", "merge", "vote"],
            "description" => "New aggregation strategy"
          }
        },
        "required" => ["team_id"]
      }
    }
  end

  defp list_teams_tool do
    %{
      "name" => "agent_studio__list_teams",
      "description" => "List all accessible teams with summary info.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{}
      }
    }
  end

  defp get_team_tool do
    %{
      "name" => "agent_studio__get_team",
      "description" => "Get full details of a team by ID, including members.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "team_id" => %{"type" => "string", "description" => "Team UUID"}
        },
        "required" => ["team_id"]
      }
    }
  end

  defp delete_team_tool do
    %{
      "name" => "agent_studio__delete_team",
      "description" => "Delete a team. Only the owner can delete.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "team_id" => %{"type" => "string", "description" => "Team UUID"}
        },
        "required" => ["team_id"]
      }
    }
  end

  defp start_run_tool do
    %{
      "name" => "agent_studio__start_run",
      "description" =>
        "Create and immediately start a run. Returns the run ID for polling " <>
          "with agent_studio__get_run. The run executes asynchronously.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Run name"},
          "prompt" => %{"type" => "string", "description" => "The prompt / task for the run"},
          "team_id" => %{
            "type" => "string",
            "description" => "Team UUID to execute (from create_team or list_teams)"
          },
          "topology" => %{
            "type" => "string",
            "enum" => ["pipeline", "parallel", "debate", "hierarchical", "round_robin"],
            "description" => "Execution topology (default: pipeline)"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default: 3600000 = 60 min)"
          },
          "cost_limit" => %{
            "type" => "number",
            "description" =>
              "Maximum cost in USD. Defaults to server-configured limit (typically $1.00). " <>
                "Cannot exceed the server-configured maximum."
          }
        },
        "required" => ["prompt"]
      }
    }
  end

  defp list_runs_tool do
    %{
      "name" => "agent_studio__list_runs",
      "description" => "List all accessible runs with status, timing, and deliverables.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{}
      }
    }
  end

  defp get_run_tool do
    %{
      "name" => "agent_studio__get_run",
      "description" =>
        "Get full run details including tasks, log count, deliverables, " <>
          "and error info. Use to poll run status after start_run.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{"type" => "string", "description" => "Run UUID"}
        },
        "required" => ["run_id"]
      }
    }
  end

  defp cancel_run_tool do
    %{
      "name" => "agent_studio__cancel_run",
      "description" =>
        "Cancel a currently running run. Only works on runs with status 'running'.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{"type" => "string", "description" => "Run UUID"}
        },
        "required" => ["run_id"]
      }
    }
  end

  defp create_schedule_tool do
    %{
      "name" => "agent_studio__create_schedule",
      "description" =>
        "Create a cron schedule for recurring runs. " <>
          "Uses standard 5-field cron: minute hour day-of-month month day-of-week. " <>
          "Example: '0 9 * * 1-5' = weekdays at 9 AM.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Schedule name"},
          "cron_expression" => %{
            "type" => "string",
            "description" => "Cron expression (5-field format)"
          },
          "timezone" => %{
            "type" => "string",
            "description" => "Timezone (default: UTC). E.g. 'America/New_York'"
          },
          "prompt" => %{
            "type" => "string",
            "description" => "The prompt / task for each scheduled run"
          },
          "team_id" => %{
            "type" => "string",
            "description" => "Team UUID to execute on each run"
          },
          "topology" => %{
            "type" => "string",
            "enum" => ["pipeline", "parallel", "debate", "hierarchical", "round_robin"],
            "description" => "Execution topology (default: pipeline)"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Per-run timeout in ms (default: 3600000 = 60 min)"
          },
          "enabled" => %{
            "type" => "boolean",
            "description" => "Whether the schedule is active (default: true)"
          }
        },
        "required" => ["cron_expression"]
      }
    }
  end

  defp list_schedules_tool do
    %{
      "name" => "agent_studio__list_schedules",
      "description" => "List all accessible schedules with status and timing info.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{}
      }
    }
  end

  defp delete_schedule_tool do
    %{
      "name" => "agent_studio__delete_schedule",
      "description" => "Delete a schedule. Only the owner can delete.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "schedule_id" => %{"type" => "string", "description" => "Schedule UUID"}
        },
        "required" => ["schedule_id"]
      }
    }
  end
end

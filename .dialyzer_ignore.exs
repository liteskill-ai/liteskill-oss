# Dialyzer ignore file — each entry suppresses a known false positive.
# Run `mix dialyzer --list-unused-filters` to detect stale entries.
#
# Categories:
#   1. ReqLLM type mismatch — Dialyzer can't resolve ReqLLM.Context struct typing,
#      causing cascading no_return/unused_fun across llm_generate.ex & stream_handler.ex
#   2. Compile-time env — Application.compile_env bakes values at compile time,
#      making one branch unreachable in the compiled BEAM (by design)
#   3. Opaque types — MapSet/Task internal struct representation exposed in module
#      attributes; Dialyzer flags legitimate usage as opaque violations
#   4. Jido library — upstream pattern match issues in dep code
#   5. Defensive guards — is_binary/is_list guards on values that are always maps
#      in practice; kept for robustness against unexpected input shapes
[
  # -- 1. ReqLLM type cascade (root: generate_text/stream_text arg mismatch) --
  {"lib/liteskill/agents/actions/llm_generate.ex", :call},
  {"lib/liteskill/agents/actions/llm_generate.ex", :guard_fail},
  {"lib/liteskill/agents/actions/llm_generate.ex", :no_return},
  {"lib/liteskill/agents/actions/llm_generate.ex", :pattern_match},
  {"lib/liteskill/agents/actions/llm_generate.ex", :unused_fun},
  {"lib/liteskill/llm/stream_handler.ex", :call},
  {"lib/liteskill/llm/stream_handler.ex", :guard_fail},
  {"lib/liteskill/llm/stream_handler.ex", :no_return},
  # runner.ex pattern_match cascades from LlmGenerate return type
  {"lib/liteskill/runs/runner.ex", :pattern_match},

  # -- 2. Compile-time env checks (Application.compile_env resolves at build time) --
  {"lib/liteskill/llm.ex", :pattern_match},

  # -- 3. Opaque type limitations --
  {"lib/liteskill/mcp_servers/client.ex", :call_without_opaque},
  {"lib/liteskill/rbac/permissions.ex", :call_without_opaque},
  {"lib/liteskill/runs/runner.ex", :call_without_opaque},

  # -- 4. Jido library upstream issues --
  {"deps/jido/lib/jido/agent.ex", :pattern_match},
  {"deps/jido/lib/jido/agent.ex", :pattern_match_cov},
  {"lib/liteskill/agents/jido_agent.ex", :invalid_contract},

  # -- 5. Defensive guard clauses (is_binary on always-map values) --
  {"lib/liteskill/builtin_tools/agent_studio.ex", :guard_fail},
  {"lib/liteskill/builtin_tools/wiki.ex", :guard_fail},
  {"lib/liteskill/data_sources/connectors/google_drive.ex", :pattern_match},
  {"lib/liteskill/rag/ingest_worker.ex", :pattern_match_cov}
]

# ReqLLM's validate_model/1 checks AWS credentials via env vars before
# the request reaches Req.Test plugs. Set a dummy token so Bedrock
# embedding tests pass on CI where no real AWS env vars exist.
System.put_env("AWS_BEARER_TOKEN_BEDROCK", "test-token-for-reqllm-validation")

ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Liteskill.Repo, :manual)

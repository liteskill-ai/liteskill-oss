# Testing

## Running Tests

```bash
# All tests
mix test

# Single file
mix test test/path_test.exs

# Re-run failures
mix test --failed
```

## Coverage

100% test coverage is required, enforced by ExCoveralls. Files excluded from coverage are listed in `coveralls.json`.

Use `# coveralls-ignore-start` / `# coveralls-ignore-stop` for genuinely unreachable branches (e.g. desktop-only code paths, production-only error handling).

## Test Configuration

### DataCase

```elixir
use Liteskill.DataCase, async: false
```

All database tests use a shared Ecto sandbox (`async: false`).

### Unit Tests

Pure unit tests (aggregates, events, parsers) use:

```elixir
use ExUnit.Case, async: true
```

### Argon2

Test config uses `t_cost: 1, m_cost: 8` for fast password hashing.

## HTTP Mocking with Req.Test

Use `plug: {Req.Test, ModuleName}` to mock HTTP calls:

```elixir
Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
  Req.Test.json(conn, %{"result" => %{"tools" => []}})
end)
```

**Important**: Req.Test does NOT trigger `into:` callbacks. Use the `plug:` option when constructing Req requests in production code to enable test substitution.

## Projector

The `Chat.Projector` runs in the **main supervision tree** — never `start_supervised!` it in tests. It's already running.

## Process Synchronization

Chat context write functions include `Process.sleep(50)` for projection consistency. In tests, prefer synchronization over additional sleeps:

```elixir
# Prefer this
_ = :sys.get_state(Liteskill.Chat.Projector)

# Or use Projector.sync/0
:ok = Liteskill.Chat.Projector.sync()
```

## Stateful Stubs

Use `Agent` for varying responses across retries:

```elixir
{:ok, counter} = Agent.start_link(fn -> 0 end)

Req.Test.stub(ModuleName, fn conn ->
  call = Agent.get_and_update(counter, &{&1, &1 + 1})
  case call do
    0 -> Plug.Conn.send_resp(conn, 429, "rate limited")
    _ -> Req.Test.json(conn, %{"result" => "ok"})
  end
end)
```

Set `backoff_ms: 1` for retry tests to avoid slow test runs.

## MCP Client Testing

```elixir
Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
  Req.Test.json(conn, %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "result" => %{"tools" => []}
  })
end)
```

## Docker-Based Testing

```bash
# Run tests with a temporary Docker Postgres
./scripts/test-with-docker.sh test

# Full precommit with Docker Postgres
./scripts/test-with-docker.sh precommit
```

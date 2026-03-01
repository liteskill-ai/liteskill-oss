defmodule Liteskill.Rag.RequestLoggerTest do
  use Liteskill.DataCase, async: false

  import Ecto.Query

  alias Liteskill.Rag.EmbeddingRequest
  alias Liteskill.Rag.RequestLogger

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "reqlog-#{System.unique_integer([:positive])}@example.com",
        name: "Test",
        oidc_sub: "reqlog-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "log_request/2" do
    test "logs non-HTTP error with request_failed status", %{user: user} do
      RequestLogger.log_request(user.id, %{
        result: {:error, :timeout},
        request_type: "embed",
        latency_ms: 100,
        input_count: 1,
        token_count: 10,
        model_id: "test-model"
      })

      request = Repo.one(from r in EmbeddingRequest, where: r.user_id == ^user.id)
      assert request.status == "error"
      assert request.error_message == "request_failed"
    end

    test "skips logging for nil user_id" do
      assert :ok = RequestLogger.log_request(nil, %{})
    end
  end
end

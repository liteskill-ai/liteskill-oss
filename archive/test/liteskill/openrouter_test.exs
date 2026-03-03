defmodule Liteskill.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Liteskill.OpenRouter

  describe "generate_pkce/0" do
    test "returns two base64url-encoded strings" do
      {verifier, challenge} = OpenRouter.generate_pkce()

      assert is_binary(verifier)
      assert is_binary(challenge)
      assert byte_size(verifier) > 0
      assert byte_size(challenge) > 0

      # Both should be valid base64url (no padding)
      assert {:ok, _} = Base.url_decode64(verifier, padding: false)
      assert {:ok, _} = Base.url_decode64(challenge, padding: false)
    end

    test "challenge is sha256 of verifier" do
      {verifier, challenge} = OpenRouter.generate_pkce()

      expected =
        :sha256
        |> :crypto.hash(verifier)
        |> Base.url_encode64(padding: false)

      assert challenge == expected
    end

    test "generates unique pairs each call" do
      {v1, _c1} = OpenRouter.generate_pkce()
      {v2, _c2} = OpenRouter.generate_pkce()

      assert v1 != v2
    end
  end

  describe "auth_url/2" do
    test "builds URL with correct query params" do
      url = OpenRouter.auth_url("https://example.com/callback", "test_challenge")

      uri = URI.parse(url)
      assert uri.host == "openrouter.ai"
      assert uri.path == "/auth"
      assert uri.scheme == "https"

      params = URI.decode_query(uri.query)
      assert params["callback_url"] == "https://example.com/callback"
      assert params["code_challenge"] == "test_challenge"
      assert params["code_challenge_method"] == "S256"
    end
  end

  describe "exchange_code/3" do
    test "returns {:ok, key} on success" do
      Req.Test.stub(OpenRouter, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["code"] == "test_code"
        assert decoded["code_verifier"] == "test_verifier"
        assert decoded["code_challenge_method"] == "S256"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"key" => "sk-or-test-key"}))
      end)

      assert {:ok, "sk-or-test-key"} =
               OpenRouter.exchange_code("test_code", "test_verifier", plug: {Req.Test, OpenRouter})
    end

    test "returns {:error, msg} on non-200 status" do
      Req.Test.stub(OpenRouter, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => "forbidden"}))
      end)

      assert {:error, "OpenRouter returned status 403"} =
               OpenRouter.exchange_code("bad_code", "verifier", plug: {Req.Test, OpenRouter})
    end

    test "returns {:error, msg} on transport error" do
      Req.Test.stub(OpenRouter, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, "OpenRouter request failed: " <> _} =
               OpenRouter.exchange_code("code", "verifier", plug: {Req.Test, OpenRouter})
    end
  end
end

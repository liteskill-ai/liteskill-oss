defmodule Liteskill.OpenRouter do
  @moduledoc """
  OpenRouter OAuth PKCE flow — generate challenges and exchange authorization codes for API keys.
  """

  use Boundary, top_level?: true, deps: [], exports: [StateStore, Models]

  @auth_url "https://openrouter.ai/auth"
  @exchange_url "https://openrouter.ai/api/v1/auth/keys"

  @doc """
  Generates a PKCE code_verifier and code_challenge (S256).

  Returns `{code_verifier, code_challenge}` where both are base64url-encoded strings.
  """
  def generate_pkce do
    verifier =
      32
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    challenge =
      :sha256
      |> :crypto.hash(verifier)
      |> Base.url_encode64(padding: false)

    {verifier, challenge}
  end

  @doc """
  Builds the OpenRouter authorization URL with the given callback_url and code_challenge.
  """
  def auth_url(callback_url, code_challenge) do
    query =
      URI.encode_query(%{
        "callback_url" => callback_url,
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      })

    "#{@auth_url}?#{query}"
  end

  @doc """
  Exchanges an authorization code for an API key.

  Accepts an `opts` keyword list merged into `Req.post/2` for testability (e.g. `plug:` for Req.Test).

  Returns `{:ok, key}` or `{:error, reason}`.
  """
  def exchange_code(code, code_verifier, opts \\ []) do
    body =
      Jason.encode!(%{
        code: code,
        code_verifier: code_verifier,
        code_challenge_method: "S256"
      })

    req_opts =
      [url: @exchange_url, headers: [{"content-type", "application/json"}], body: body]
      |> Keyword.merge(test_plug_opts())
      |> Keyword.merge(opts)

    case Req.post(Req.new(retry: false), req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"key" => key}}} ->
        {:ok, key}

      {:ok, %Req.Response{status: status}} ->
        {:error, "OpenRouter returned status #{status}"}

      {:error, reason} ->
        {:error, "OpenRouter request failed: #{inspect(reason)}"}
    end
  end

  defp test_plug_opts do
    if Application.get_env(:liteskill, :env) == :test do
      [plug: {Req.Test, __MODULE__}]
    else
      # coveralls-ignore-start — only reached in non-test environments
      []
      # coveralls-ignore-stop
    end
  end
end

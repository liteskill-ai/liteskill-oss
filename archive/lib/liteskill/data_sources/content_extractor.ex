defmodule Liteskill.DataSources.ContentExtractor do
  @moduledoc """
  Extracts plain text from various content types.

  Supports text/plain, text/markdown, text/html (basic strip), application/json.
  Future phases will add PDF, DOCX, etc.
  """

  @doc "Extracts text content from raw bytes + content_type."
  @spec extract(binary(), String.t()) :: {:ok, String.t()} | {:error, :unsupported_content_type}
  def extract(content, "text/plain"), do: {:ok, content}
  def extract(content, "text/markdown"), do: {:ok, content}
  def extract(content, "markdown"), do: {:ok, content}
  def extract(content, "text/html"), do: {:ok, strip_html(content)}
  def extract(content, "text/" <> _), do: {:ok, content}
  def extract(content, "application/json"), do: {:ok, content}
  def extract(_content, _type), do: {:error, :unsupported_content_type}

  defp strip_html(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/s, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/s, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end

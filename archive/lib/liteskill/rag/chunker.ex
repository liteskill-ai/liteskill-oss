defmodule Liteskill.Rag.Chunker do
  @moduledoc """
  Recursive text splitter for RAG document chunking.

  Splits text using a hierarchy of separators (paragraphs → lines → sentences → words),
  then merges small pieces back up to the target chunk size with configurable overlap.
  """

  @default_separators ["\n\n", "\n", ". ", " "]
  @default_chunk_size 2000
  @default_overlap 200

  @doc """
  Split text into chunks suitable for embedding.

  Returns a list of `%{content: str, position: int, token_count: int}`.

  ## Options

    * `:chunk_size` - target chunk size in characters (default: #{@default_chunk_size})
    * `:overlap` - overlap between chunks in characters (default: #{@default_overlap})
    * `:separators` - list of separators to try, in order (default: paragraph, line, sentence, word)
  """
  def split(text, opts \\ [])
  def split(nil, _opts), do: []
  def split("", _opts), do: []

  def split(text, opts) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    overlap = Keyword.get(opts, :overlap, @default_overlap)
    separators = Keyword.get(opts, :separators, @default_separators)

    text
    |> recursive_split(separators, chunk_size)
    |> merge_chunks(chunk_size, overlap)
    |> Enum.with_index()
    |> Enum.map(fn {content, idx} ->
      %{content: content, position: idx, token_count: estimate_tokens(content)}
    end)
  end

  defp recursive_split(text, _separators, chunk_size) when byte_size(text) <= chunk_size do
    [text]
  end

  defp recursive_split(text, [], chunk_size) do
    force_split(text, chunk_size)
  end

  defp recursive_split(text, [sep | rest], chunk_size) do
    pieces = String.split(text, sep)

    if length(pieces) == 1 do
      recursive_split(text, rest, chunk_size)
    else
      pieces
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn piece ->
        if byte_size(piece) > chunk_size do
          recursive_split(piece, rest, chunk_size)
        else
          [piece]
        end
      end)
    end
  end

  defp force_split(text, chunk_size) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(&Enum.join/1)
  end

  defp merge_chunks(pieces, chunk_size, overlap) do
    pieces
    |> Enum.reduce({[], ""}, fn piece, {acc, current} ->
      candidate =
        if current == "" do
          piece
        else
          current <> " " <> piece
        end

      if byte_size(candidate) <= chunk_size do
        {acc, candidate}
      else
        if current == "" do
          {[piece | acc], ""}
        else
          overlap_text = get_overlap(current, overlap)
          next = if overlap_text == "", do: piece, else: overlap_text <> " " <> piece
          {[current | acc], next}
        end
      end
    end)
    |> then(fn
      {acc, ""} -> Enum.reverse(acc)
      {acc, remaining} -> Enum.reverse([remaining | acc])
    end)
  end

  defp get_overlap(_text, overlap) when overlap <= 0, do: ""

  defp get_overlap(text, overlap) do
    text
    |> String.slice(-overlap, overlap)
    |> String.trim()
  end

  defp estimate_tokens(text) do
    max(div(byte_size(text), 4), 1)
  end
end

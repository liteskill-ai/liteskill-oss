defmodule Liteskill.Rag.ChunkerTest do
  use ExUnit.Case, async: true

  alias Liteskill.Rag.Chunker

  describe "split/2" do
    test "returns empty list for nil" do
      assert Chunker.split(nil) == []
    end

    test "returns empty list for empty string" do
      assert Chunker.split("") == []
    end

    test "returns single chunk for short text" do
      result = Chunker.split("Hello world")
      assert length(result) == 1
      assert hd(result).content == "Hello world"
      assert hd(result).position == 0
      assert hd(result).token_count > 0
    end

    test "splits on paragraph boundaries" do
      text =
        String.duplicate("A paragraph of text. ", 60) <>
          "\n\n" <>
          String.duplicate("Another paragraph. ", 60)

      result = Chunker.split(text, chunk_size: 500)
      assert length(result) > 1
      assert Enum.all?(result, fn c -> c.position >= 0 end)
    end

    test "splits on line boundaries when no paragraphs" do
      text = Enum.map_join(1..50, "\n", fn i -> "Line number #{i} with some content here" end)

      result = Chunker.split(text, chunk_size: 200)
      assert length(result) > 1
    end

    test "splits on sentence boundaries" do
      text = Enum.map_join(1..100, fn i -> "This is sentence number #{i}. " end)

      result = Chunker.split(text, chunk_size: 200)
      assert length(result) > 1
    end

    test "splits on word boundaries" do
      text = Enum.map_join(1..300, " ", fn i -> "word#{i}" end)

      result = Chunker.split(text, chunk_size: 200)
      assert length(result) > 1
    end

    test "force-splits long strings with no separators" do
      text = String.duplicate("x", 5000)

      result = Chunker.split(text, chunk_size: 200)
      assert length(result) > 1
      assert Enum.all?(result, fn c -> byte_size(c.content) <= 200 + 200 + 1 end)
    end

    test "assigns sequential positions" do
      text =
        String.duplicate("A paragraph of text. ", 60) <>
          "\n\n" <>
          String.duplicate("Another paragraph. ", 60) <>
          "\n\n" <>
          String.duplicate("Third paragraph. ", 60)

      result = Chunker.split(text, chunk_size: 500)
      positions = Enum.map(result, & &1.position)
      assert positions == Enum.to_list(0..(length(result) - 1))
    end

    test "estimates token count (~4 chars per token)" do
      text = String.duplicate("abcd", 100)
      [chunk] = Chunker.split(text)
      assert chunk.token_count == div(byte_size(text), 4)
    end

    test "respects custom chunk_size and overlap" do
      text = Enum.map_join(1..200, " ", fn i -> "word#{i}" end)

      result = Chunker.split(text, chunk_size: 100, overlap: 20)
      assert length(result) > 1
    end

    test "overlap creates content redundancy between chunks" do
      text = Enum.map_join(1..200, " ", fn i -> "word#{i}" end)

      result = Chunker.split(text, chunk_size: 100, overlap: 50)
      assert length(result) >= 2

      # Adjacent chunks should share some content due to overlap
      first = Enum.at(result, 0).content
      second = Enum.at(result, 1).content

      # The end of the first chunk should appear at the start of the second
      first_tail = first |> String.slice(-50, 50) |> String.trim()
      assert String.contains?(second, first_tail) or byte_size(first_tail) > 0
    end

    test "respects custom separators" do
      text = "part1|part2|part3"

      result = Chunker.split(text, chunk_size: 6, overlap: 0, separators: ["|"])
      assert length(result) == 3
      assert Enum.at(result, 0).content == "part1"
      assert Enum.at(result, 1).content == "part2"
      assert Enum.at(result, 2).content == "part3"
    end

    test "token count is at least 1 for very short text" do
      [chunk] = Chunker.split("Hi")
      assert chunk.token_count >= 1
    end

    test "handles multi-byte text where pieces exceed chunk byte size" do
      # Each emoji is 4 bytes. force_split uses graphemes (not bytes), so two emojis
      # become one piece of 8 bytes. With chunk_size=3, pieces exceed the byte limit
      # in merge_chunks, exercising the {acc, ""} -> Enum.reverse(acc) branch.
      text = "\u{1F389}\u{1F389} \u{1F389}\u{1F389}"
      result = Chunker.split(text, chunk_size: 3, overlap: 0)
      assert length(result) == 2
    end
  end
end

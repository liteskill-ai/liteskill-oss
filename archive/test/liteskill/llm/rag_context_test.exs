defmodule Liteskill.LLM.RagContextTest do
  use ExUnit.Case, async: true

  alias Liteskill.LLM.RagContext

  defp make_result(opts) do
    chunk_id = Keyword.get(opts, :chunk_id, Ecto.UUID.generate())
    doc_id = Keyword.get(opts, :doc_id, Ecto.UUID.generate())
    title = Keyword.get(opts, :title, "Test Document")
    content = Keyword.get(opts, :content, "Some chunk content")
    position = Keyword.get(opts, :position, 0)
    source_name = Keyword.get(opts, :source_name, "wiki")
    metadata = Keyword.get(opts, :metadata, %{})
    relevance_score = Keyword.get(opts, :relevance_score, nil)

    %{
      chunk: %{
        id: chunk_id,
        content: content,
        position: position,
        document: %{
          id: doc_id,
          title: title,
          metadata: metadata,
          source: %{name: source_name}
        }
      },
      relevance_score: relevance_score
    }
  end

  describe "build_system_prompt/2" do
    test "returns nil when no results and no system prompt" do
      assert RagContext.build_system_prompt([], nil) == nil
    end

    test "returns conversation prompt when no results" do
      assert RagContext.build_system_prompt([], "Be helpful") == "Be helpful"
    end

    test "builds prompt with results and no conversation prompt" do
      results = [make_result(title: "Doc A", content: "chunk text A")]
      prompt = RagContext.build_system_prompt(results, nil)

      assert prompt =~ "MUST cite your sources"
      assert prompt =~ "[uuid:DOCUMENT_UUID]"
      assert prompt =~ "<knowledge_base>"
      assert prompt =~ "<document index=\"1\""
      assert prompt =~ "title=\"Doc A\""
      assert prompt =~ "chunk text A"
      refute prompt =~ "Be helpful"
    end

    test "builds prompt with results and conversation prompt" do
      results = [make_result(title: "Doc B")]
      prompt = RagContext.build_system_prompt(results, "Be brief")

      assert prompt =~ "Be brief"
      assert prompt =~ "MUST cite your sources"
      assert prompt =~ "<knowledge_base>"
      assert prompt =~ "title=\"Doc B\""
    end

    test "escapes XML in document titles" do
      results = [make_result(title: "A <b>bold</b> & \"quoted\" title")]
      prompt = RagContext.build_system_prompt(results, nil)

      assert prompt =~ "A &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot; title"
    end

    test "handles nil document title" do
      results = [make_result(title: nil)]
      prompt = RagContext.build_system_prompt(results, nil)

      assert prompt =~ "title=\"\""
    end

    test "indexes multiple documents sequentially" do
      results = [
        make_result(title: "First"),
        make_result(title: "Second"),
        make_result(title: "Third")
      ]

      prompt = RagContext.build_system_prompt(results, nil)

      assert prompt =~ "index=\"1\""
      assert prompt =~ "index=\"2\""
      assert prompt =~ "index=\"3\""
    end
  end

  describe "serialize_sources/1" do
    test "serializes results to JSONB-ready maps" do
      chunk_id = Ecto.UUID.generate()
      doc_id = Ecto.UUID.generate()

      results = [
        make_result(
          chunk_id: chunk_id,
          doc_id: doc_id,
          title: "Wiki Page",
          content: "wiki content",
          position: 3,
          source_name: "wiki",
          relevance_score: 0.95,
          metadata: %{"wiki_document_id" => "abc-123"}
        )
      ]

      [serialized] = RagContext.serialize_sources(results)

      assert serialized["chunk_id"] == chunk_id
      assert serialized["document_id"] == doc_id
      assert serialized["document_title"] == "Wiki Page"
      assert serialized["source_name"] == "wiki"
      assert serialized["content"] == "wiki content"
      assert serialized["position"] == 3
      assert serialized["relevance_score"] == 0.95
      assert serialized["source_uri"] == "/wiki/abc-123"
    end

    test "sets source_uri to nil for non-wiki documents" do
      results = [make_result(metadata: %{})]
      [serialized] = RagContext.serialize_sources(results)

      assert serialized["source_uri"] == nil
    end

    test "handles nil metadata" do
      results = [make_result(metadata: nil)]
      [serialized] = RagContext.serialize_sources(results)

      assert serialized["source_uri"] == nil
    end

    test "handles nil relevance_score" do
      results = [make_result(relevance_score: nil)]
      [serialized] = RagContext.serialize_sources(results)

      assert serialized["relevance_score"] == nil
    end
  end
end

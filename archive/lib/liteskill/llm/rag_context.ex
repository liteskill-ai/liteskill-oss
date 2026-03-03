defmodule Liteskill.LLM.RagContext do
  @moduledoc """
  Builds system prompts enriched with RAG context and citation instructions.
  Serializes RAG results for storage on messages.
  """

  @citation_instructions """
  You have access to relevant knowledge base documents provided below. \
  When using information from these documents, you MUST cite your sources \
  inline using the format [uuid:DOCUMENT_UUID]. Place the citation immediately \
  after the claim or fact it supports.

  Example: "The project uses event sourcing for persistence [uuid:abc12345-def6-7890-abcd-ef1234567890]."

  Rules for citations:
  - Use the exact document UUID shown in each <document> tag's uuid attribute
  - Only cite documents you actually reference
  - A single sentence may have multiple citations if it draws from multiple sources
  - If you don't use information from the provided documents, don't include citations
  """

  @doc """
  Build a system prompt combining:
  1. The conversation's own system_prompt (if any)
  2. RAG citation instructions
  3. RAG context chunks formatted with XML tags
  """
  def build_system_prompt([], nil), do: nil
  def build_system_prompt([], system_prompt) when is_binary(system_prompt), do: system_prompt

  def build_system_prompt(rag_results, conversation_system_prompt) do
    parts =
      if conversation_system_prompt do
        [conversation_system_prompt, @citation_instructions, format_rag_context(rag_results)]
      else
        [@citation_instructions, format_rag_context(rag_results)]
      end

    Enum.join(parts, "\n\n")
  end

  defp format_rag_context(results) do
    chunks_text =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {result, idx} ->
        chunk = result.chunk
        doc = chunk.document

        """
        <document index="#{idx}" uuid="#{doc.id}" title="#{escape_xml(doc.title)}">
        #{chunk.content}
        </document>\
        """
      end)

    "<knowledge_base>\n#{chunks_text}\n</knowledge_base>"
  end

  defp escape_xml(nil), do: ""

  defp escape_xml(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  @doc """
  Serialize RAG results for storage in message.rag_sources JSONB.
  """
  def serialize_sources(results) do
    Enum.map(results, fn result ->
      chunk = result.chunk
      doc = chunk.document
      source = doc.source
      wiki_doc_id = get_in(doc.metadata || %{}, ["wiki_document_id"])

      %{
        "chunk_id" => chunk.id,
        "document_id" => doc.id,
        "document_title" => doc.title,
        "source_name" => source.name,
        "content" => chunk.content,
        "position" => chunk.position,
        "relevance_score" => Map.get(result, :relevance_score),
        "source_uri" => build_source_uri(wiki_doc_id)
      }
    end)
  end

  defp build_source_uri(nil), do: nil
  defp build_source_uri(wiki_doc_id), do: "/wiki/#{wiki_doc_id}"
end

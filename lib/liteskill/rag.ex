defmodule Liteskill.Rag do
  use Boundary,
    top_level?: true,
    deps: [
      Liteskill.Authorization,
      Liteskill.DataSources,
      Liteskill.LlmModels,
      Liteskill.LlmProviders,
      Liteskill.Settings
    ],
    exports: [
      Collection,
      Source,
      Document,
      Chunk,
      Chunker,
      CohereClient,
      DocumentSyncWorker,
      EmbedQueue,
      EmbeddingRequest,
      IngestWorker,
      Pipeline,
      ReembedWorker,
      WikiSyncWorker
    ]

  @moduledoc """
  The RAG context. Manages collections, sources, documents, chunks,
  embedding generation, and semantic search.
  """

  alias Liteskill.Rag.{
    Collection,
    Source,
    Document,
    Chunk,
    CohereClient,
    EmbedQueue,
    IngestWorker
  }

  alias Liteskill.Repo

  import Ecto.Query

  # --- Collections ---

  def create_collection(attrs, user_id) do
    %Collection{}
    |> Collection.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  def list_collections(user_id) do
    Collection
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc """
  Returns collections the user can access: their own collections plus
  Wiki collections from users who share wiki spaces with them.
  """
  def list_accessible_collections(user_id) do
    own = list_collections(user_id)
    own_ids = Enum.map(own, & &1.id)

    shared =
      shared_wiki_collection_ids(user_id, own_ids)
      |> case do
        [] ->
          []

        ids ->
          Collection
          |> where([c], c.id in ^ids)
          |> order_by([c], asc: c.name)
          |> Repo.all()
      end

    own ++ shared
  end

  defp shared_wiki_collection_ids(user_id, exclude_ids) do
    wiki_space_ids = Liteskill.Authorization.accessible_entity_ids("wiki_space", user_id)

    space_owner_ids =
      from(d in Liteskill.DataSources.Document,
        where: d.id in subquery(wiki_space_ids) and d.user_id != ^user_id,
        select: d.user_id,
        distinct: true
      )
      |> Repo.all()

    case space_owner_ids do
      [] ->
        []

      ids ->
        from(c in Collection,
          where: c.name == "Wiki" and c.user_id in ^ids and c.id not in ^exclude_ids,
          select: c.id
        )
        |> Repo.all()
    end
  end

  def get_collection(id, user_id) do
    case Repo.get(Collection, id) do
      nil -> {:error, :not_found}
      %Collection{user_id: ^user_id} = collection -> {:ok, collection}
      _ -> {:error, :not_found}
    end
  end

  def update_collection(id, attrs, user_id) do
    with {:ok, collection} <- get_collection(id, user_id) do
      collection
      |> Collection.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_collection(id, user_id) do
    with {:ok, collection} <- get_collection(id, user_id) do
      Repo.delete(collection)
    end
  end

  # --- Sources ---

  def create_source(collection_id, attrs, user_id) do
    with {:ok, _collection} <- get_collection(collection_id, user_id) do
      %Source{}
      |> Source.changeset(
        attrs
        |> Map.put(:collection_id, collection_id)
        |> Map.put(:user_id, user_id)
      )
      |> Repo.insert()
    end
  end

  def list_sources(collection_id, user_id) do
    with {:ok, _collection} <- get_collection(collection_id, user_id) do
      sources =
        Source
        |> where([s], s.collection_id == ^collection_id)
        |> order_by([s], asc: s.name)
        |> Repo.all()

      {:ok, sources}
    end
  end

  def get_source(id, user_id) do
    case Repo.get(Source, id) do
      nil -> {:error, :not_found}
      %Source{user_id: ^user_id} = source -> {:ok, source}
      _ -> {:error, :not_found}
    end
  end

  def update_source(id, attrs, user_id) do
    with {:ok, source} <- get_source(id, user_id) do
      source
      |> Source.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_source(id, user_id) do
    with {:ok, source} <- get_source(id, user_id) do
      Repo.delete(source)
    end
  end

  # --- Documents ---

  def create_document(source_id, attrs, user_id) do
    with {:ok, _source} <- get_source(source_id, user_id) do
      attrs =
        attrs
        |> Map.put(:source_id, source_id)
        |> Map.put(:user_id, user_id)
        |> maybe_hash_content()

      %Document{}
      |> Document.changeset(attrs)
      |> Repo.insert()
    end
  end

  def list_documents(source_id, user_id) do
    with {:ok, _source} <- get_source(source_id, user_id) do
      documents =
        Document
        |> where([d], d.source_id == ^source_id)
        |> order_by([d], asc: d.title)
        |> Repo.all()

      {:ok, documents}
    end
  end

  def get_document(id, user_id) do
    case Repo.get(Document, id) do
      nil -> {:error, :not_found}
      %Document{user_id: ^user_id} = document -> {:ok, document}
      _ -> {:error, :not_found}
    end
  end

  def delete_document(id, user_id) do
    with {:ok, document} <- get_document(id, user_id) do
      Repo.delete(document)
    end
  end

  # --- Embedding ---

  def embed_chunks(document_id, chunks, user_id, opts \\ []) do
    with {:ok, document} <- get_document(document_id, user_id),
         {:ok, source} <- get_source(document.source_id, user_id),
         {:ok, collection} <- get_collection(source.collection_id, user_id) do
      {plug_opts, _rest} = Keyword.split(opts, [:plug])
      dimensions = Keyword.get(opts, :dimensions, collection.embedding_dimensions)
      texts = Enum.map(chunks, & &1.content)

      case EmbedQueue.embed(
             texts,
             [{:input_type, "search_document"}, {:dimensions, dimensions}, {:user_id, user_id}] ++
               plug_opts
           ) do
        {:ok, embeddings} ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          chunk_rows =
            chunks
            |> Enum.zip(embeddings)
            |> Enum.map(fn {chunk, embedding} ->
              %{
                id: Ecto.UUID.generate(),
                content: chunk.content,
                content_hash: content_hash(chunk.content),
                position: chunk.position,
                metadata: Map.get(chunk, :metadata, %{}),
                token_count: Map.get(chunk, :token_count),
                embedding: Pgvector.new(embedding),
                document_id: document_id,
                inserted_at: now,
                updated_at: now
              }
            end)

          Repo.transaction(fn ->
            Repo.insert_all(Chunk, chunk_rows)

            document
            |> Document.changeset(%{
              status: "embedded",
              chunk_count: length(chunks),
              error_message: nil
            })
            |> Repo.update!()
          end)

        {:error, reason} ->
          document
          |> Document.changeset(%{status: "error", error_message: format_embed_error(reason)})
          |> Repo.update()

          {:error, reason}
      end
    end
  end

  # --- Search ---

  def search(collection_id, query, user_id, opts \\ []) do
    with {:ok, collection} <- get_collection(collection_id, user_id) do
      {plug_opts, _rest} = Keyword.split(opts, [:plug])
      dimensions = Keyword.get(opts, :dimensions, collection.embedding_dimensions)
      limit = Keyword.get(opts, :limit, 20)

      case CohereClient.embed(
             [query],
             [{:input_type, "search_query"}, {:dimensions, dimensions}, {:user_id, user_id}] ++
               plug_opts
           ) do
        {:ok, [query_embedding]} ->
          results = vector_search(collection_id, query_embedding, limit)
          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def rerank(query, chunks, opts \\ []) do
    {plug_opts, rest} = Keyword.split(opts, [:plug])
    top_n = Keyword.get(rest, :top_n, 5)
    user_id = Keyword.get(rest, :user_id)
    texts = Enum.map(chunks, fn %{chunk: c} -> c.content end)

    user_opts = if user_id, do: [{:user_id, user_id}], else: []

    case CohereClient.rerank(query, texts, [{:top_n, top_n}] ++ user_opts ++ plug_opts) do
      {:ok, results} ->
        ranked =
          Enum.map(results, fn %{"index" => idx, "relevance_score" => score} ->
            %{chunk: Enum.at(chunks, idx).chunk, relevance_score: score}
          end)

        {:ok, ranked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def search_and_rerank(collection_id, query, user_id, opts \\ []) do
    {plug_opts, rest} = Keyword.split(opts, [:plug])
    search_limit = Keyword.get(rest, :search_limit, 50)
    top_n = Keyword.get(rest, :top_n, 5)
    dimensions = Keyword.get(rest, :dimensions)

    search_opts = [{:limit, search_limit}] ++ plug_opts
    search_opts = if dimensions, do: [{:dimensions, dimensions} | search_opts], else: search_opts

    with {:ok, search_results} <- search(collection_id, query, user_id, search_opts) do
      case rerank(query, search_results, [{:top_n, top_n}, {:user_id, user_id}] ++ plug_opts) do
        {:ok, _ranked} = ok ->
          ok

        {:error, _reason} ->
          fallback = Enum.take(search_results, top_n)
          {:ok, Enum.map(fallback, fn r -> Map.put(r, :relevance_score, nil) end)}
      end
    end
  end

  @doc """
  Searches a collection with ACL awareness. Works for both owned and shared
  collections. For shared wiki collections, only returns chunks from wiki
  spaces the user has access to.
  """
  def search_accessible(collection_id, query, user_id, opts \\ []) do
    case Repo.get(Collection, collection_id) do
      nil ->
        {:error, :not_found}

      collection ->
        {plug_opts, rest} = Keyword.split(opts, [:plug])
        dimensions = Keyword.get(rest, :dimensions, collection.embedding_dimensions)
        search_limit = Keyword.get(rest, :search_limit, 50)
        top_n = Keyword.get(rest, :top_n, 10)

        case CohereClient.embed(
               [query],
               [{:input_type, "search_query"}, {:dimensions, dimensions}, {:user_id, user_id}] ++
                 plug_opts
             ) do
          {:ok, [query_embedding]} ->
            results =
              vector_search_accessible(collection_id, user_id, query_embedding, search_limit)

            if results == [] do
              {:ok, []}
            else
              case rerank(query, results, [{:top_n, top_n}, {:user_id, user_id}] ++ plug_opts) do
                {:ok, _} = ok ->
                  ok

                {:error, _} ->
                  fallback = Enum.take(results, top_n)
                  {:ok, Enum.map(fallback, fn r -> Map.put(r, :relevance_score, nil) end)}
              end
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # --- Context Augmentation ---

  def augment_context(query, user_id, opts \\ []) do
    {plug_opts, _rest} = Keyword.split(opts, [:plug])

    case CohereClient.embed(
           [query],
           [{:input_type, "search_query"}, {:dimensions, 1024}, {:user_id, user_id}] ++ plug_opts
         ) do
      {:ok, [query_embedding]} ->
        results = vector_search_all(user_id, query_embedding, 100)

        if results == [] do
          {:ok, []}
        else
          chunks = Enum.map(results, & &1.chunk)
          preloaded = Repo.preload(chunks, document: :source)

          enriched =
            Enum.zip_with(results, preloaded, fn r, c -> %{r | chunk: c} end)

          if length(enriched) >= 40 do
            case rerank(query, enriched, [{:top_n, 40}, {:user_id, user_id}] ++ plug_opts) do
              {:ok, _ranked} = ok -> ok
              {:error, _} -> {:ok, add_nil_scores(Enum.take(enriched, 40))}
            end
          else
            {:ok, add_nil_scores(enriched)}
          end
        end

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp add_nil_scores(results) do
    Enum.map(results, fn r -> Map.put(r, :relevance_score, nil) end)
  end

  # --- Wiki Sync Helpers ---

  def find_or_create_wiki_collection(user_id) do
    case Repo.one(
           from(c in Collection,
             where: c.name == "Wiki" and c.user_id == ^user_id
           )
         ) do
      %Collection{} = coll -> {:ok, coll}
      nil -> create_collection(%{name: "Wiki"}, user_id)
    end
  end

  def find_or_create_wiki_source(collection_id, user_id) do
    case Repo.one(
           from(s in Source,
             where:
               s.name == "wiki" and s.collection_id == ^collection_id and s.user_id == ^user_id
           )
         ) do
      %Source{} = source -> {:ok, source}
      nil -> create_source(collection_id, %{name: "wiki", source_type: "manual"}, user_id)
    end
  end

  def find_rag_document_by_wiki_id(wiki_document_id, user_id) do
    wiki_space_ids = Liteskill.Authorization.accessible_entity_ids("wiki_space", user_id)

    case Repo.one(
           from(d in Document,
             where:
               fragment("? ->> 'wiki_document_id' = ?", d.metadata, ^wiki_document_id) and
                 (d.user_id == ^user_id or
                    fragment("(?->>'wiki_space_id')::uuid", d.metadata) in subquery(
                      wiki_space_ids
                    ))
           )
         ) do
      %Document{} = doc ->
        {:ok, doc}

      nil ->
        # Fallback for docs missing wiki_space_id metadata (pre-backfill data)
        Repo.one(
          from(d in Document,
            where: fragment("? ->> 'wiki_document_id' = ?", d.metadata, ^wiki_document_id)
          )
        )
        |> resolve_wiki_acl(user_id)
    end
  end

  def get_rag_document_for_source_doc(document_id, user_id) do
    wiki_space_ids = Liteskill.Authorization.accessible_entity_ids("wiki_space", user_id)

    case Repo.one(
           from(d in Document,
             where:
               (fragment("? ->> 'wiki_document_id' = ?", d.metadata, ^document_id) or
                  fragment("? ->> 'source_document_id' = ?", d.metadata, ^document_id)) and
                 (d.user_id == ^user_id or
                    fragment("(?->>'wiki_space_id')::uuid", d.metadata) in subquery(
                      wiki_space_ids
                    ))
           )
         ) do
      %Document{} = doc ->
        {:ok, doc}

      nil ->
        # Fallback for docs missing wiki_space_id metadata (pre-backfill data)
        Repo.one(
          from(d in Document,
            where:
              fragment("? ->> 'wiki_document_id' = ?", d.metadata, ^document_id) or
                fragment("? ->> 'source_document_id' = ?", d.metadata, ^document_id)
          )
        )
        |> resolve_wiki_acl(user_id)
    end
  end

  def list_chunks_for_document(rag_document_id) do
    Chunk
    |> where([c], c.document_id == ^rag_document_id)
    |> order_by([c], asc: c.position)
    |> Repo.all()
  end

  def delete_document_chunks(document_id) do
    {count, _} =
      from(c in Chunk, where: c.document_id == ^document_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  # --- Generic Sync Helpers ---

  def find_or_create_collection_for_source(source_name, user_id) do
    case Repo.one(
           from(c in Collection,
             where: c.name == ^source_name and c.user_id == ^user_id
           )
         ) do
      %Collection{} = coll -> {:ok, coll}
      nil -> create_collection(%{name: source_name}, user_id)
    end
  end

  def find_or_create_rag_source_for_source(collection_id, source_name, user_id) do
    case Repo.one(
           from(s in Source,
             where:
               s.name == ^source_name and s.collection_id == ^collection_id and
                 s.user_id == ^user_id
           )
         ) do
      %Source{} = source -> {:ok, source}
      nil -> create_source(collection_id, %{name: source_name, source_type: "manual"}, user_id)
    end
  end

  def find_rag_document_by_source_doc_id(source_document_id, user_id) do
    wiki_space_ids = Liteskill.Authorization.accessible_entity_ids("wiki_space", user_id)

    case Repo.one(
           from(d in Document,
             where:
               fragment("? ->> 'source_document_id' = ?", d.metadata, ^source_document_id) and
                 (d.user_id == ^user_id or
                    fragment("(?->>'wiki_space_id')::uuid", d.metadata) in subquery(
                      wiki_space_ids
                    ))
           )
         ) do
      %Document{} = doc ->
        {:ok, doc}

      nil ->
        # Fallback for docs missing wiki_space_id metadata (pre-backfill data)
        Repo.one(
          from(d in Document,
            where: fragment("? ->> 'source_document_id' = ?", d.metadata, ^source_document_id)
          )
        )
        |> resolve_wiki_acl(user_id)
    end
  end

  # --- Ingest ---

  def ingest_url(collection_id, url, user_id, opts \\ []) do
    with {:ok, _collection} <- get_collection(collection_id, user_id) do
      method = Keyword.get(opts, :method, "GET")
      headers = Keyword.get(opts, :headers, %{})
      plug = Keyword.get(opts, :plug, false)
      chunk_size = Keyword.get(opts, :chunk_size)
      overlap = Keyword.get(opts, :overlap)

      chunk_opts =
        %{}
        |> maybe_put_arg("chunk_size", chunk_size)
        |> maybe_put_arg("overlap", overlap)

      args = %{
        "url" => url,
        "collection_id" => collection_id,
        "user_id" => user_id,
        "method" => method,
        "headers" => headers,
        "chunk_opts" => chunk_opts,
        "plug" => plug
      }

      IngestWorker.new(args) |> Oban.insert()
    end
  end

  defp maybe_put_arg(map, _key, nil), do: map
  defp maybe_put_arg(map, key, value), do: Map.put(map, key, value)

  # --- Private ---

  # Fallback ACL check for RAG documents missing wiki_space_id in metadata.
  # Resolves the wiki space via wiki_document_id, checks ACL, and backfills
  # wiki_space_id for future queries (self-healing).
  defp resolve_wiki_acl(nil, _user_id), do: {:error, :not_found}

  defp resolve_wiki_acl(%Document{} = doc, user_id) do
    cond do
      doc.user_id == user_id ->
        {:ok, doc}

      is_binary(doc.metadata["wiki_document_id"]) ->
        with %Liteskill.DataSources.Document{} = wiki_doc <-
               Repo.get(Liteskill.DataSources.Document, doc.metadata["wiki_document_id"]),
             space_id when is_binary(space_id) <- Liteskill.DataSources.get_space_id(wiki_doc),
             {:ok, _role} <-
               Liteskill.Authorization.get_role("wiki_space", space_id, user_id) do
          new_metadata = Map.put(doc.metadata, "wiki_space_id", space_id)
          Repo.update(Ecto.Changeset.change(doc, %{metadata: new_metadata}))
          {:ok, %{doc | metadata: new_metadata}}
        else
          _ -> {:error, :not_found}
        end

      true ->
        {:error, :not_found}
    end
  end

  defp vector_search_all(user_id, query_embedding, limit) do
    query_vector = Pgvector.new(query_embedding)
    wiki_space_ids = Liteskill.Authorization.accessible_entity_ids("wiki_space", user_id)

    from(c in Chunk,
      join: d in Document,
      on: d.id == c.document_id,
      join: s in Source,
      on: s.id == d.source_id,
      join: coll in Collection,
      on: coll.id == s.collection_id,
      where:
        coll.user_id == ^user_id or
          fragment("(?->>'wiki_space_id')::uuid", d.metadata) in subquery(wiki_space_ids),
      where: not is_nil(c.embedding),
      order_by: fragment("embedding <=> ?", ^query_vector),
      limit: ^limit,
      select: %{chunk: c, distance: fragment("embedding <=> ?", ^query_vector)}
    )
    |> Repo.all()
  end

  defp vector_search_accessible(collection_id, user_id, query_embedding, limit) do
    query_vector = Pgvector.new(query_embedding)
    wiki_space_ids = Liteskill.Authorization.accessible_entity_ids("wiki_space", user_id)

    from(c in Chunk,
      join: d in Document,
      on: d.id == c.document_id,
      join: s in Source,
      on: s.id == d.source_id,
      join: coll in Collection,
      on: coll.id == s.collection_id,
      where: s.collection_id == ^collection_id,
      where:
        coll.user_id == ^user_id or
          fragment("(?->>'wiki_space_id')::uuid", d.metadata) in subquery(wiki_space_ids),
      where: not is_nil(c.embedding),
      order_by: fragment("embedding <=> ?", ^query_vector),
      limit: ^limit,
      select: %{chunk: c, distance: fragment("embedding <=> ?", ^query_vector)}
    )
    |> Repo.all()
  end

  defp vector_search(collection_id, query_embedding, limit) do
    query_vector = Pgvector.new(query_embedding)

    from(c in Chunk,
      join: d in Document,
      on: d.id == c.document_id,
      join: s in Source,
      on: s.id == d.source_id,
      where: s.collection_id == ^collection_id,
      where: not is_nil(c.embedding),
      order_by: fragment("embedding <=> ?", ^query_vector),
      limit: ^limit,
      select: %{chunk: c, distance: fragment("embedding <=> ?", ^query_vector)}
    )
    |> Repo.all()
  end

  # coveralls-ignore-next-line
  defp content_hash(nil), do: nil
  defp content_hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp maybe_hash_content(%{content: content} = attrs) when is_binary(content) do
    Map.put(attrs, :content_hash, content_hash(content))
  end

  defp maybe_hash_content(attrs), do: attrs

  # --- Re-embedding support ---

  @doc """
  Returns the total number of chunks across all collections.
  """
  def total_chunk_count do
    Repo.aggregate(Chunk, :count, :id)
  end

  @doc """
  Clears all embeddings from all chunks and resets embedded documents to pending.
  Returns `{:ok, %{chunks_cleared: n, documents_reset: n}}`.
  """
  def clear_all_embeddings do
    {chunks_cleared, _} =
      from(c in Chunk, where: not is_nil(c.embedding))
      |> Repo.update_all(set: [embedding: nil])

    {documents_reset, _} =
      from(d in Document, where: d.status == "embedded")
      |> Repo.update_all(set: [status: "pending"])

    {:ok, %{chunks_cleared: chunks_cleared, documents_reset: documents_reset}}
  end

  @doc """
  Returns documents that need re-embedding (pending status with chunks), paginated.
  """
  def list_documents_for_reembedding(limit, offset) do
    from(d in Document,
      where: d.status == "pending" and d.chunk_count > 0,
      order_by: [asc: d.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  defp format_embed_error(%{status: status, body: %{"Message" => msg}}),
    do: "HTTP #{status}: #{msg}"

  # coveralls-ignore-start
  defp format_embed_error(%{status: status, body: %{"message" => msg}}),
    do: "HTTP #{status}: #{msg}"

  defp format_embed_error(%{status: status}), do: "HTTP #{status}"
  defp format_embed_error(reason) when is_binary(reason), do: reason
  defp format_embed_error(reason), do: inspect(reason)
  # coveralls-ignore-stop
end

# RAG Context

`Liteskill.Rag` manages the RAG pipeline: collections, sources, documents, chunks, embeddings, and search.

## Boundary

```elixir
use Boundary,
  top_level?: true,
  deps: [Liteskill.Authorization, Liteskill.DataSources, Liteskill.LlmModels, Liteskill.LlmProviders, Liteskill.Settings],
  exports: [Collection, Source, Document, Chunk, Chunker, CohereClient, DocumentSyncWorker, EmbedQueue, EmbeddingClient, EmbeddingRequest, IngestWorker, OpenAIEmbeddingClient, Pipeline, ReembedWorker, WikiSyncWorker]
```

## Data Model

- **Collection** — Top-level grouping, per user, with configurable embedding dimension (256–1536, default 1024)
- **Source** — A source within a collection (e.g. "wiki", "manual")
- **Document** — Content with title, status, metadata, and content hash
- **Chunk** — Text chunk with position, token count, and pgvector embedding

## Collection & Source CRUD

Standard CRUD with user ownership checks. Collections and sources are scoped to the creating user.

## Embedding

`embed_chunks(document_id, chunks, user_id, opts)`:
1. Validates ownership chain (document → source → collection)
2. Sends texts to `EmbedQueue` for embedding
3. Inserts chunk rows with pgvector embeddings in a transaction
4. Updates document status to `"embedded"`

## Search

| Function | Description |
|----------|-------------|
| `search(collection_id, query, user_id, opts)` | Vector search within a collection |
| `rerank(query, chunks, opts)` | Rerank results via Cohere |
| `search_and_rerank(collection_id, query, user_id, opts)` | Combined search + rerank |
| `search_accessible(collection_id, query, user_id, opts)` | ACL-aware search for shared collections |
| `augment_context(query, user_id, opts)` | Cross-collection search for conversation context |

## Wiki Integration

- `find_or_create_wiki_collection(user_id)` — Gets or creates the "Wiki" collection
- `find_or_create_wiki_source(collection_id, user_id)` — Gets or creates the "wiki" source
- `find_rag_document_by_wiki_id(wiki_document_id, user_id)` — Finds RAG doc by wiki doc ID

## URL Ingestion

The `IngestWorker` (Oban job) handles URL-based ingestion:
1. Fetches URL content via Req
2. Validates text content (rejects binary types)
3. Auto-creates source from domain name
4. Chunks content and enqueues for embedding
5. Retries up to 3 times on transient failures

## Background Workers

| Worker | Queue | Purpose |
|--------|-------|---------|
| `IngestWorker` | `rag_ingest` | URL-based document ingestion |
| `WikiSyncWorker` | `rag_ingest` | Sync wiki pages to RAG |
| `DocumentSyncWorker` | `rag_ingest` | Sync data source documents to RAG |
| `ReembedWorker` | `rag_ingest` | Re-embed all documents after model change |

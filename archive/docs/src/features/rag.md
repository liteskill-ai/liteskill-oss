# RAG (Retrieval-Augmented Generation)

Liteskill includes a full RAG pipeline: document ingestion, chunking, embedding generation, semantic search, and reranking.

## Pipeline

1. **Ingest** — Documents are added to a collection via URL, manual upload, or data source sync
2. **Chunk** — Documents are split into chunks using a recursive text splitter (paragraph → line → sentence → word boundaries)
3. **Embed** — Chunks are embedded using a configured embedding model (Cohere or OpenAI-compatible)
4. **Search** — User queries are embedded and matched against chunks using pgvector cosine similarity
5. **Rerank** — Search results are optionally reranked using a Cohere rerank model

## Data Model

- **Collection** — Top-level grouping (e.g. "Wiki", "Engineering Docs") with configurable embedding dimension (256–1536, default 1024)
- **Source** — A source within a collection (e.g. "wiki", "manual")
- **Document** — A single document with content, metadata, and content hash
- **Chunk** — A text chunk with position, token count, and its pgvector embedding

## Embedding

Embeddings are generated via `Liteskill.Rag.EmbedQueue`, a GenServer that batches requests and manages throughput. Two client implementations:

- `CohereClient` — For Cohere's embed and rerank APIs (including Cohere on AWS Bedrock)
- `OpenAIEmbeddingClient` — For OpenAI-compatible embedding endpoints

## Context Augmentation

During conversations, RAG context is injected automatically:

1. The user's message is embedded
2. All accessible collections are searched
3. Top results are optionally reranked
4. Relevant chunks are included as context for the LLM
5. RAG sources are tracked per message for citation

## Wiki Integration

Wiki pages are automatically synced to RAG collections. When a wiki page is created or updated, a background job (`WikiSyncWorker`) updates the corresponding RAG document and re-embeds its chunks.

## URL Ingestion

The `IngestWorker` (Oban job) handles URL-based document ingestion:

1. Fetches URL via Req
2. Validates content type (rejects binary content)
3. Auto-creates a source from the domain name
4. Chunks the response body
5. Enqueues embedding via `EmbedQueue`
6. Retries up to 3 times on transient failures

## Re-embedding

Admins can trigger a full re-embedding of all documents (e.g. after changing the embedding model) via the `ReembedWorker`.

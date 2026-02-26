# Configuring a RAG Data Source

RAG (Retrieval-Augmented Generation) lets you feed your own documents into conversations. When RAG is enabled, Liteskill searches your document collections for relevant context and includes it with your messages to the LLM.

## Prerequisites

- Liteskill running (see [Initial Setup](quick-start.md))
- An LLM provider configured with an **embedding** model
- Documents you want to make searchable

## Create a Wiki Space

1. Navigate to `Wiki` in the sidebar (or go to `/wiki`).
1. Click "New Space".
1. Give it a name (e.g. "Engineering Docs").

## Add Documents

You can add nested documents in this page, called "children".

### External Connectors

For bulk document sync, configure an external data source:

1. Navigate to `Sources` and click "Add Source".
1. Select a source type:
    - **Google Drive** — Service account JSON + folder ID
    - **SharePoint** — Tenant ID, site URL, client credentials
    - **Confluence** — Base URL, username, API token, space key
    - **Jira** — Base URL, username, API token, project key
    - **GitHub** — Personal access token, repository
    - **GitLab** — Personal access token, project path
1. Fill in the credentials and click Save.
1. Click "Sync" to pull documents from the source.

## Using RAG in Conversations

Once your documents are embedded, RAG context is automatically injected into conversations:

1. Start a new conversation.
1. Ask a question related to your documents.
1. Liteskill embeds your query, searches across your accessible collections, and includes the most relevant chunks as context for the LLM.
1. RAG sources are displayed alongside the assistant's response for transparency.

## Wiki Integration

Wiki pages are automatically indexed for RAG. When you create or edit a wiki page, a background job updates the corresponding RAG document and re-embeds its chunks. See the [Wiki](../features/wiki.md) documentation for details.

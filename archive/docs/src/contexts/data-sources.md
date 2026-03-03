# Data Sources Context

`Liteskill.DataSources` manages external data connectors and their documents.

## Boundary

```elixir
use Boundary,
  top_level?: true,
  deps: [Liteskill.Authorization, Liteskill.Rbac, Liteskill.BuiltinSources, Liteskill.Reports],
  exports: [Source, Document, SyncWorker, Connector, ConnectorRegistry, ContentExtractor, Connectors.GoogleDrive, Connectors.Wiki, WikiExport, WikiImport]
```

## Supported Source Types

| Type | Config Fields |
|------|--------------|
| **Google Drive** | Service account JSON, folder ID |
| **SharePoint** | Tenant ID, site URL, client ID, client secret |
| **Confluence** | Base URL, username, API token, space key |
| **Jira** | Base URL, username, API token, project key |
| **GitHub** | Personal access token, repository |
| **GitLab** | Personal access token, project path |

## Source CRUD

| Function | Description |
|----------|-------------|
| `list_sources(user_id)` | Lists sources (owned + ACL'd + built-in) |
| `list_sources_with_counts(user_id)` | Same with document counts |
| `get_source(id, user_id)` | Gets with access check |
| `create_source(attrs, user_id)` | Creates with RBAC and owner ACL |
| `update_source(id, attrs, user_id)` | Updates (built-in sources cannot be updated) |
| `delete_source(id, user_id)` | Deletes source and its documents |

## Document Management

| Function | Description |
|----------|-------------|
| `list_documents(source_ref, user_id)` | Lists documents for a source |
| `list_documents_paginated(source_ref, user_id, opts)` | Paginated with search |
| `get_document(id, user_id)` | Gets with ownership or wiki ACL check |
| `create_document(source_ref, attrs, user_id)` | Creates (wiki docs auto-create ACLs) |
| `create_child_document(source_ref, parent_id, attrs, user_id)` | Creates nested document |
| `update_document(id, attrs, user_id)` | Updates (wiki docs trigger RAG sync) |
| `delete_document(id, user_id)` | Deletes with role checks for wiki docs |

## Sync Pipeline

- `start_sync(source_id, user_id)` — Enqueues a `SyncWorker` Oban job
- `SyncWorker` uses the `ConnectorRegistry` to dispatch to the correct connector (Google Drive, SharePoint, etc.)
- Each connector fetches updated documents, creates/updates local records, and triggers RAG re-embedding

## Wiki Integration

- `Connectors.Wiki` handles built-in wiki documents
- `WikiExport` exports wiki spaces as structured documents
- `WikiImport` imports wiki content from external sources
- `export_report_to_wiki/3` converts a report to wiki pages

## Content Extraction

`ContentExtractor` handles converting various document formats to plain text for embedding.

## Built-in Sources

`Liteskill.BuiltinSources` defines virtual sources that exist in code (e.g. the Wiki source). These appear in the source list but cannot be modified or deleted.

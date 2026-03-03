# Wiki

Liteskill includes a built-in collaborative wiki for documentation and knowledge management.

## Structure

The wiki uses a hierarchical document model:

- **Spaces** — Top-level wiki documents (root pages with no parent)
- **Pages** — Child documents nested under spaces
- Pages can be nested to arbitrary depth

All wiki documents use the built-in `"builtin:wiki"` source reference.

## Creating Content

- Create a new wiki space from the wiki page (`/wiki`)
- Add child pages under any space or page
- Edit pages with markdown content
- Pages have titles, slugs, and optional content

## Sharing

Wiki spaces use ACL-based sharing:

- The space creator is the **owner**
- Owners can grant **viewer**, **editor**, or **manager** access to other users
- **Editors** can create and edit pages within the space
- **Managers** can also delete pages and manage access
- Shared spaces appear in the recipient's wiki

## RAG Integration

Wiki content is automatically indexed for RAG:

- When a page is created or updated, a `WikiSyncWorker` job is enqueued
- The worker creates/updates a RAG document and re-embeds chunks
- Wiki collections are shared with users who have access to the wiki space
- This means RAG search results include relevant wiki content from shared spaces

## Export & Import

- Wiki spaces can be exported via the `/wiki/:space_id/export` route
- Reports can be exported to wiki pages via `DataSources.export_report_to_wiki/3`
- Wiki content can be imported from external sources

## Routes

- `/wiki` — Wiki home (list all accessible spaces)
- `/wiki/:document_id` — View/edit a wiki page

# Reports

Reports are structured documents with hierarchical sections, markdown rendering, and a comment/review workflow.

## Structure

- **Report** — Top-level document with a title and owner
- **Sections** — Infinitely nested sections with titles, content, and position ordering
- **Comments** — Threaded comments on sections or the report itself

## Section Management

Sections are addressed by path (e.g. `"Executive Summary > Key Findings"`). The path-based API supports:

- **Upsert** — Create or update a section at a path
- **Delete** — Remove a section and its children
- **Move** — Reposition a section among its siblings

Batch operations via `modify_sections/3` allow multiple actions in a single transaction.

## Comments

Comments support a review workflow:

- Comments have an `author_type` (`"user"` or `"agent"`)
- Comments can be **open** or **addressed**
- Resolving a comment creates a reply and marks it as addressed
- Comments can be threaded (replies to replies)

An LLM agent can be instructed to address open comments, making edits and resolving each one.

## Markdown Rendering

`render_markdown/2` produces a complete markdown document from a report:

- Section titles become `#`, `##`, `###` headers based on nesting depth
- Comments are rendered as blockquotes with status labels
- Comments can be included or excluded

## Access Control

Reports use the standard ACL system:

- Creator is the owner
- Access can be granted to other users at the manager level
- Shared reports appear in the recipient's report list

## Run Integration

Reports can be created as part of an agent run, linking the report to its source run for traceability. The `ReportBuilder` in the runs system generates structured report output from pipeline execution.

## Routes

- `/reports` — List all reports
- `/reports/:report_id` — View/edit a report

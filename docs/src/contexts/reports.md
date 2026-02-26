# Reports Context

`Liteskill.Reports` manages structured reports with nested sections and a comment/review workflow.

## Boundary

```elixir
use Boundary,
  top_level?: true,
  deps: [Liteskill.Accounts, Liteskill.Authorization, Liteskill.Rbac],
  exports: [Report, ReportSection, SectionComment]
```

## Report CRUD

| Function | Description |
|----------|-------------|
| `create_report(user_id, title, opts)` | Creates a report with RBAC check and owner ACL |
| `list_reports(user_id)` | Lists accessible reports |
| `list_reports_paginated(user_id, page)` | Paginated list (20 per page) |
| `get_report(report_id, user_id)` | Gets report with ordered sections |
| `delete_report(report_id, user_id)` | Deletes (owner only) |

## Section Management

Sections are addressed by `>` delimited paths (e.g. `"Summary > Findings"`).

| Function | Description |
|----------|-------------|
| `upsert_section(report_id, user_id, path, content)` | Create or update a section |
| `upsert_sections(report_id, user_id, sections)` | Batch upsert |
| `modify_sections(report_id, user_id, actions)` | Batch upsert/delete/move |
| `update_section_content(section_id, user_id, attrs)` | Direct update |
| `delete_section(section_id, user_id)` | Delete a section |

## Comments

| Function | Description |
|----------|-------------|
| `add_comment(section_id, user_id, body, author_type)` | Add a section comment |
| `add_report_comment(report_id, user_id, body, author_type)` | Add a report-level comment |
| `resolve_comment(comment_id, user_id, body)` | Resolve with a reply |
| `reply_to_comment(comment_id, user_id, body, author_type)` | Thread a reply |
| `manage_comments(report_id, user_id, actions)` | Batch add/resolve |

## Rendering

- `render_markdown(report, opts)` — Full markdown with headers and optional comments
- `section_tree(report)` — Nested tree structure for UI rendering

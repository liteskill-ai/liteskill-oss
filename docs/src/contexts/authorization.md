# Authorization Context

`Liteskill.Authorization` provides centralized access control for all entity types via a single `entity_acls` table.

## Boundary

```elixir
use Boundary, top_level?: true, deps: [Liteskill.Groups], exports: [EntityAcl, Roles]
```

## Role Hierarchy

`viewer` < `editor` < `manager` < `owner`

| Role | Permissions |
|------|------------|
| **viewer** | Read-only access |
| **editor** | Can edit content (wiki spaces only) |
| **manager** | Edit + grant/revoke viewer/editor/manager access |
| **owner** | Full control (delete, demote anyone, transfer ownership) |

## Access Checks

| Function | Description |
|----------|-------------|
| `has_access?(entity_type, entity_id, user_id)` | Any access (direct or group-based) |
| `get_role(entity_type, entity_id, user_id)` | Highest role across direct + group ACLs |
| `can_manage?(entity_type, entity_id, user_id)` | Manager or owner |
| `can_edit?(entity_type, entity_id, user_id)` | Editor, manager, or owner |
| `owner?(entity_type, entity_id, user_id)` | Owner only |

## ACL Management

| Function | Description |
|----------|-------------|
| `create_owner_acl(entity_type, entity_id, user_id)` | Auto-created on resource creation |
| `grant_access(entity_type, entity_id, grantor_id, grantee_user_id, role)` | Grant user access |
| `grant_group_access(entity_type, entity_id, grantor_id, group_id, role)` | Grant group access |
| `update_role(entity_type, entity_id, grantor_id, target_user_id, new_role)` | Change a user's role |
| `revoke_access(entity_type, entity_id, revoker_id, target_user_id)` | Revoke user access |
| `leave(entity_type, entity_id, user_id)` | User leaves (owners cannot leave) |

## Query Helpers

- `accessible_entity_ids(entity_type, user_id)` — Subquery of entity IDs the user can access
- `usage_accessible_entity_ids(entity_type, user_id)` — Same but excludes "owner" role

## Entity Types

The ACL system is used across: `conversation`, `report`, `wiki_space`, `mcp_server`, `agent_definition`, `team_definition`, `run`, `schedule`, `source`, `llm_provider`, `llm_model`.

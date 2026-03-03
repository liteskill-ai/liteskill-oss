# Groups Context

`Liteskill.Groups` manages user groups and memberships, used for group-based ACL authorization.

## Boundary

```elixir
use Boundary, top_level?: true, deps: [], exports: [Group, GroupMembership]
```

## Group Management

| Function | Description |
|----------|-------------|
| `create_group(name, creator_id)` | Creates a group; creator becomes owner member |
| `list_groups(user_id)` | Lists groups the user belongs to |
| `get_group(id, user_id)` | Gets a group (requires membership) |
| `delete_group(group_id, user_id)` | Deletes a group (creator only) |

## Membership Management

| Function | Description |
|----------|-------------|
| `add_member(group_id, requester_id, target_user_id, role)` | Adds a member (creator only) |
| `remove_member(group_id, requester_id, target_user_id)` | Removes a member (creator only, cannot remove owner) |
| `leave_group(group_id, user_id)` | User leaves (creator cannot leave) |

## Admin Functions

Admin functions bypass creator/membership checks:

- `list_all_groups/0` — Lists all groups with memberships and creator preloaded
- `admin_get_group/1`, `admin_get_group_by_name/1`
- `admin_list_members/1`, `admin_add_member/3`, `admin_remove_member/2`
- `admin_delete_group/1`

## Usage with ACLs

Groups are used in the Authorization context for group-based access. When a group is granted access to an entity (e.g. a conversation), all members of that group inherit that access via a join with `group_memberships`.

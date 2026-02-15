defmodule Liteskill.ReportsTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Reports
  alias Liteskill.Authorization.EntityAcl
  alias Liteskill.Reports.Report

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        name: "Other",
        oidc_sub: "other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner, other: other}
  end

  describe "address_comments_system_prompt/0" do
    test "returns a non-empty string" do
      prompt = Reports.address_comments_system_prompt()
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "mentions report tools" do
      prompt = Reports.address_comments_system_prompt()
      assert prompt =~ "reports__get"
      assert prompt =~ "reports__modify_sections"
      assert prompt =~ "reports__comment"
    end
  end

  describe "create_report/2" do
    test "creates report with owner ACL", %{owner: owner} do
      assert {:ok, report} = Reports.create_report(owner.id, "My Report")
      assert report.title == "My Report"
      assert report.user_id == owner.id

      acl =
        Repo.one!(
          from(a in EntityAcl,
            where: a.entity_type == "report" and a.entity_id == ^report.id
          )
        )

      assert acl.user_id == owner.id
      assert acl.role == "owner"
    end
  end

  describe "list_reports/1" do
    test "returns owned reports", %{owner: owner} do
      {:ok, r1} = Reports.create_report(owner.id, "Report 1")
      {:ok, r2} = Reports.create_report(owner.id, "Report 2")

      reports = Reports.list_reports(owner.id)
      ids = Enum.map(reports, & &1.id)
      assert r1.id in ids
      assert r2.id in ids
    end

    test "returns shared reports", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Shared Report")
      {:ok, _acl} = Reports.grant_access(report.id, owner.id, other.email)

      reports = Reports.list_reports(other.id)
      assert Enum.any?(reports, &(&1.id == report.id))
    end

    test "does not return unshared reports", %{owner: owner, other: other} do
      {:ok, _report} = Reports.create_report(owner.id, "Private")

      reports = Reports.list_reports(other.id)
      assert reports == []
    end
  end

  describe "list_reports_paginated/2" do
    test "returns paginated results", %{owner: owner} do
      for i <- 1..3, do: {:ok, _} = Reports.create_report(owner.id, "Report #{i}")

      result = Reports.list_reports_paginated(owner.id, 1)
      assert result.page == 1
      assert result.total == 3
      assert result.total_pages == 1
      assert length(result.reports) == 3
    end

    test "returns empty page when no reports", %{other: other} do
      result = Reports.list_reports_paginated(other.id, 1)
      assert result.reports == []
      assert result.total == 0
      assert result.total_pages == 1
    end

    test "includes shared reports", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Shared")
      {:ok, _} = Reports.grant_access(report.id, owner.id, other.email)

      result = Reports.list_reports_paginated(other.id, 1)
      assert result.total == 1
      assert hd(result.reports).id == report.id
    end
  end

  describe "get_report/2" do
    test "returns report with sections for owner", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:ok, loaded} = Reports.get_report(report.id, owner.id)
      assert loaded.id == report.id
      assert loaded.sections == []
    end

    test "returns not_found for non-existent", %{owner: owner} do
      assert {:error, :not_found} = Reports.get_report(Ecto.UUID.generate(), owner.id)
    end

    test "returns not_found for unauthorized user", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Private")
      assert {:error, :not_found} = Reports.get_report(report.id, other.id)
    end
  end

  describe "delete_report/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Deletable")
      assert {:ok, _} = Reports.delete_report(report.id, owner.id)
      assert Repo.get(Report, report.id) == nil
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Protected")
      {:ok, _} = Reports.grant_access(report.id, owner.id, other.email)
      assert {:error, :forbidden} = Reports.delete_report(report.id, other.id)
    end
  end

  describe "upsert_section/4" do
    test "creates a top-level section", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      assert {:ok, section} =
               Reports.upsert_section(report.id, owner.id, "Introduction", "Hello world")

      assert section.title == "Introduction"
      assert section.content == "Hello world"
      assert section.parent_section_id == nil
    end

    test "creates nested sections", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      assert {:ok, section} =
               Reports.upsert_section(
                 report.id,
                 owner.id,
                 "Findings > Key Points",
                 "Important stuff"
               )

      assert section.title == "Key Points"
      assert section.content == "Important stuff"
      assert section.parent_section_id != nil
    end

    test "updates existing section content", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Intro", "V1")
      {:ok, updated} = Reports.upsert_section(report.id, owner.id, "Intro", "V2")

      assert updated.content == "V2"
    end

    test "deeply nested path", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      assert {:ok, section} =
               Reports.upsert_section(
                 report.id,
                 owner.id,
                 "A > B > C",
                 "Deep content"
               )

      assert section.title == "C"
      assert section.content == "Deep content"
    end

    test "invalid empty path returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:error, :invalid_path} = Reports.upsert_section(report.id, owner.id, "", "content")
    end

    test "unauthorized user cannot upsert", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      assert {:error, :not_found} =
               Reports.upsert_section(report.id, other.id, "Intro", "content")
    end
  end

  describe "delete_section/2" do
    test "deletes a section", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "content")
      assert {:ok, _} = Reports.delete_section(section.id, owner.id)
    end

    test "returns not_found for missing section", %{owner: owner} do
      assert {:error, :not_found} = Reports.delete_section(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "update_section_content/3" do
    test "updates content of an existing section", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Original")

      assert {:ok, updated} =
               Reports.update_section_content(section.id, owner.id, %{content: "Updated content"})

      assert updated.content == "Updated content"
      assert updated.title == "Intro"
    end

    test "updates title of an existing section", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")

      assert {:ok, updated} =
               Reports.update_section_content(section.id, owner.id, %{title: "Introduction"})

      assert updated.title == "Introduction"
      assert updated.content == "Content"
    end

    test "updates both title and content", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Original")

      assert {:ok, updated} =
               Reports.update_section_content(section.id, owner.id, %{
                 title: "Introduction",
                 content: "New content"
               })

      assert updated.title == "Introduction"
      assert updated.content == "New content"
    end

    test "returns not_found for non-existent section", %{owner: owner} do
      assert {:error, :not_found} =
               Reports.update_section_content(Ecto.UUID.generate(), owner.id, %{content: "x"})
    end

    test "unauthorized user cannot update", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Original")

      assert {:error, :not_found} =
               Reports.update_section_content(section.id, other.id, %{content: "Hacked"})
    end

    test "can clear content", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Has content")

      assert {:ok, updated} =
               Reports.update_section_content(section.id, owner.id, %{content: ""})

      assert updated.content in [nil, ""]
    end
  end

  describe "render_markdown/1" do
    test "renders empty report", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Empty")
      {:ok, report} = Reports.get_report(report.id, owner.id)
      assert Reports.render_markdown(report) == ""
    end

    test "renders flat sections", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Intro", "Hello")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Body", "World")

      {:ok, report} = Reports.get_report(report.id, owner.id)
      md = Reports.render_markdown(report)
      assert md =~ "# Intro"
      assert md =~ "Hello"
      assert md =~ "# Body"
      assert md =~ "World"
    end

    test "renders nested sections with correct depth", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Section > Sub", "Nested content")

      {:ok, report} = Reports.get_report(report.id, owner.id)
      md = Reports.render_markdown(report)
      assert md =~ "# Section"
      assert md =~ "## Sub"
      assert md =~ "Nested content"
    end
  end

  describe "grant_access/4" do
    test "owner can grant access", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:ok, acl} = Reports.grant_access(report.id, owner.id, other.email)
      assert acl.role == "manager"
    end

    test "non-owner cannot grant access", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:error, :no_access} = Reports.grant_access(report.id, other.id, owner.email)
    end

    test "returns error for non-existent user", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:error, :user_not_found} = Reports.grant_access(report.id, owner.id, "nobody@x.com")
    end
  end

  describe "revoke_access/3" do
    test "owner can revoke member access", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.grant_access(report.id, owner.id, other.email)
      assert {:ok, _} = Reports.revoke_access(report.id, owner.id, other.id)
    end

    test "cannot revoke owner access", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:error, :cannot_revoke_owner} = Reports.revoke_access(report.id, owner.id, owner.id)
    end

    test "returns not_found for non-existent ACL", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:error, :not_found} = Reports.revoke_access(report.id, owner.id, other.id)
    end
  end

  describe "leave_report/2" do
    test "member can leave", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.grant_access(report.id, owner.id, other.email)
      assert {:ok, _} = Reports.leave_report(report.id, other.id)
    end

    test "owner cannot leave", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:error, :owner_cannot_leave} = Reports.leave_report(report.id, owner.id)
    end

    test "returns not_found for non-member", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:error, :not_found} = Reports.leave_report(report.id, other.id)
    end
  end

  describe "group-based access" do
    test "user can access report shared with their group", %{owner: owner, other: other} do
      {:ok, group} = Liteskill.Groups.create_group("Test Group", owner.id)
      {:ok, _} = Liteskill.Groups.add_member(group.id, owner.id, other.id)

      {:ok, report} = Reports.create_report(owner.id, "Group Shared")

      {:ok, _} =
        Liteskill.Authorization.grant_group_access(
          "report",
          report.id,
          owner.id,
          group.id,
          "manager"
        )

      # Other user can now access via group
      assert {:ok, _} = Reports.get_report(report.id, other.id)

      # And see it in their list
      reports = Reports.list_reports(other.id)
      assert Enum.any?(reports, &(&1.id == report.id))
    end
  end

  describe "EntityAcl changeset validation" do
    test "rejects both user_id and group_id set" do
      changeset =
        EntityAcl.changeset(%EntityAcl{}, %{
          entity_type: "report",
          entity_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          group_id: Ecto.UUID.generate(),
          role: "manager"
        })

      assert {:error, _} = Ecto.Changeset.apply_action(changeset, :insert)
    end

    test "rejects neither user_id nor group_id set" do
      changeset =
        EntityAcl.changeset(%EntityAcl{}, %{
          entity_type: "report",
          entity_id: Ecto.UUID.generate(),
          role: "manager"
        })

      assert {:error, _} = Ecto.Changeset.apply_action(changeset, :insert)
    end
  end

  describe "upsert_section with overlapping paths" do
    test "reuses existing intermediate sections", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      # Create "A > B > C" — creates A, B, C
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "A > B > C", "First leaf")

      # Create "A > B > D" — should reuse existing A and B, only create D
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "A > B > D", "Second leaf")

      assert section.title == "D"
      assert section.content == "Second leaf"
    end
  end

  describe "upsert_sections/3" do
    test "creates multiple sections in a single transaction", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      sections = [
        %{path: "Introduction", content: "Hello"},
        %{path: "Body", content: "World"},
        %{path: "Body > Details", content: "Nested"}
      ]

      assert {:ok, results} = Reports.upsert_sections(report.id, owner.id, sections)
      assert length(results) == 3
      assert Enum.any?(results, &(&1.path == "Introduction"))
      assert Enum.any?(results, &(&1.path == "Body"))
      assert Enum.any?(results, &(&1.path == "Body > Details"))
    end

    test "accepts string keys", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      sections = [
        %{"path" => "Intro", "content" => "Hi"}
      ]

      assert {:ok, [result]} = Reports.upsert_sections(report.id, owner.id, sections)
      assert result.path == "Intro"
    end

    test "returns error for empty path in batch", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      sections = [
        %{path: "Good", content: "ok"},
        %{path: "", content: "bad"}
      ]

      assert {:error, :invalid_path} = Reports.upsert_sections(report.id, owner.id, sections)
    end

    test "unauthorized user cannot batch upsert", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      assert {:error, :not_found} =
               Reports.upsert_sections(report.id, other.id, [%{path: "A", content: "B"}])
    end
  end

  describe "modify_sections/3" do
    test "upsert action creates sections", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [
        %{action: "upsert", path: "Intro", content: "Hello"},
        %{action: "upsert", path: "Body > Details", content: "Nested"}
      ]

      assert {:ok, results} = Reports.modify_sections(report.id, owner.id, actions)
      assert length(results) == 2
      assert Enum.any?(results, &(&1.action == "upsert" && &1.path == "Intro"))
      assert Enum.any?(results, &(&1.action == "upsert" && &1.path == "Body > Details"))
    end

    test "delete action removes a section by path", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "ToDelete", "gone")

      actions = [%{action: "delete", path: "ToDelete"}]
      assert {:ok, [result]} = Reports.modify_sections(report.id, owner.id, actions)
      assert result.action == "delete"
      assert result.path == "ToDelete"

      {:ok, loaded} = Reports.get_report(report.id, owner.id)
      assert loaded.sections == []
    end

    test "move action reorders among siblings", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "A", "first")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "B", "second")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "C", "third")

      # Move C to position 0 (top)
      actions = [%{action: "move", path: "C", position: 0}]
      assert {:ok, [result]} = Reports.modify_sections(report.id, owner.id, actions)
      assert result.action == "move"
      assert result.position == 0

      {:ok, loaded} = Reports.get_report(report.id, owner.id)
      titles = Enum.map(loaded.sections, & &1.title)
      assert titles == ["C", "A", "B"]
    end

    test "mixed actions in one call", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Old", "remove me")

      actions = [
        %{action: "upsert", path: "New", content: "fresh"},
        %{action: "delete", path: "Old"}
      ]

      assert {:ok, results} = Reports.modify_sections(report.id, owner.id, actions)
      assert length(results) == 2

      {:ok, loaded} = Reports.get_report(report.id, owner.id)
      titles = Enum.map(loaded.sections, & &1.title)
      assert "New" in titles
      refute "Old" in titles
    end

    test "delete non-existent path rolls back", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{action: "delete", path: "Ghost"}]
      assert {:error, :section_not_found} = Reports.modify_sections(report.id, owner.id, actions)
    end

    test "move non-existent path rolls back", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{action: "move", path: "Ghost", position: 0}]
      assert {:error, :section_not_found} = Reports.modify_sections(report.id, owner.id, actions)
    end

    test "invalid action type returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{action: "bogus", path: "X"}]
      assert {:error, :unknown_action} = Reports.modify_sections(report.id, owner.id, actions)
    end

    test "missing action field returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{path: "X", content: "Y"}]
      assert {:error, :missing_action} = Reports.modify_sections(report.id, owner.id, actions)
    end

    test "move without position returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{action: "move", path: "X"}]
      assert {:error, :invalid_position} = Reports.modify_sections(report.id, owner.id, actions)
    end

    test "move with empty path returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{action: "move", path: "", position: 0}]
      assert {:error, :invalid_path} = Reports.modify_sections(report.id, owner.id, actions)
    end

    test "invalid path returns error for upsert", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{action: "upsert", path: "", content: "X"}]
      assert {:error, :invalid_path} = Reports.modify_sections(report.id, owner.id, actions)
    end

    test "invalid path returns error for delete", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{action: "delete", path: ""}]
      assert {:error, :invalid_path} = Reports.modify_sections(report.id, owner.id, actions)
    end

    test "move reorders nested sections among siblings", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Parent > A", "first")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Parent > B", "second")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Parent > C", "third")

      actions = [%{action: "move", path: "Parent > C", position: 0}]
      assert {:ok, _} = Reports.modify_sections(report.id, owner.id, actions)

      {:ok, loaded} = Reports.get_report(report.id, owner.id)
      md = Reports.render_markdown(loaded)
      c_pos = :binary.match(md, "## C") |> elem(0)
      a_pos = :binary.match(md, "## A") |> elem(0)
      assert c_pos < a_pos
    end

    test "accepts string keys", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{"action" => "upsert", "path" => "Intro", "content" => "Hi"}]
      assert {:ok, [result]} = Reports.modify_sections(report.id, owner.id, actions)
      assert result.path == "Intro"
    end

    test "unauthorized user returns not_found", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{action: "upsert", path: "A", content: "B"}]
      assert {:error, :not_found} = Reports.modify_sections(report.id, other.id, actions)
    end
  end

  describe "add_comment/4" do
    test "adds agent comment to section", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")

      assert {:ok, comment} = Reports.add_comment(section.id, owner.id, "Looks good", "agent")
      assert comment.body == "Looks good"
      assert comment.author_type == "agent"
      assert comment.status == "open"
      assert comment.section_id == section.id
      assert comment.report_id == report.id
      assert comment.user_id == owner.id
    end

    test "adds user comment to section", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")

      assert {:ok, comment} = Reports.add_comment(section.id, owner.id, "Needs work", "user")
      assert comment.author_type == "user"
    end

    test "rejects invalid author_type", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")

      assert {:error, :invalid_author_type} =
               Reports.add_comment(section.id, owner.id, "Bad", "robot")
    end

    test "returns not_found for non-existent section", %{owner: owner} do
      assert {:error, :not_found} =
               Reports.add_comment(Ecto.UUID.generate(), owner.id, "Orphan", "agent")
    end

    test "unauthorized user cannot add comment", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")

      assert {:error, :not_found} = Reports.add_comment(section.id, other.id, "Nope", "user")
    end
  end

  describe "resolve_comment/3" do
    test "marks comment as addressed and creates agent reply", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, comment} = Reports.add_comment(section.id, owner.id, "Fix this", "user")

      assert {:ok, resolved} =
               Reports.resolve_comment(comment.id, owner.id, "Done, fixed the typo")

      assert resolved.status == "addressed"

      # Verify reply was created
      {:ok, comments} = Reports.list_section_comments(section.id, owner.id)
      reply = Enum.find(comments, &(&1.parent_comment_id == comment.id))
      assert reply != nil
      assert reply.body == "Done, fixed the typo"
      assert reply.author_type == "agent"
    end

    test "returns not_found for non-existent comment", %{owner: owner} do
      assert {:error, :not_found} =
               Reports.resolve_comment(Ecto.UUID.generate(), owner.id, "reply")
    end

    test "unauthorized user cannot resolve", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, comment} = Reports.add_comment(section.id, owner.id, "Fix this", "user")

      assert {:error, :not_found} = Reports.resolve_comment(comment.id, other.id, "reply")
    end
  end

  describe "list_section_comments/2" do
    test "lists comments ordered by inserted_at", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, c1} = Reports.add_comment(section.id, owner.id, "First", "user")
      {:ok, c2} = Reports.add_comment(section.id, owner.id, "Second", "agent")

      assert {:ok, comments} = Reports.list_section_comments(section.id, owner.id)
      assert length(comments) == 2
      assert hd(comments).id == c1.id
      assert List.last(comments).id == c2.id
    end

    test "returns not_found for non-existent section", %{owner: owner} do
      assert {:error, :not_found} =
               Reports.list_section_comments(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "manage_comments/3" do
    test "add action creates agent comment", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")

      actions = [%{"action" => "add", "path" => "Intro", "body" => "Agent note"}]
      assert {:ok, [result]} = Reports.manage_comments(report.id, owner.id, actions)
      assert result.action == "add"
      assert result.path == "Intro"
      assert result.comment_id != nil
    end

    test "resolve action marks comment addressed and creates reply", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, comment} = Reports.add_comment(section.id, owner.id, "Fix this", "user")

      actions = [
        %{"action" => "resolve", "comment_id" => comment.id, "body" => "Fixed the issue"}
      ]

      assert {:ok, [result]} = Reports.manage_comments(report.id, owner.id, actions)
      assert result.action == "resolve"
      assert result.comment_id == comment.id
      assert result.reply_id != nil
    end

    test "resolve already-addressed comment returns already_addressed", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, comment} = Reports.add_comment(section.id, owner.id, "Fix this", "user")
      {:ok, _} = Reports.resolve_comment(comment.id, owner.id, "Addressed")

      actions = [
        %{"action" => "resolve", "comment_id" => comment.id, "body" => "Again"}
      ]

      assert {:ok, [result]} = Reports.manage_comments(report.id, owner.id, actions)
      assert result.already_addressed == true
    end

    test "mixed add and resolve in one call", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, comment} = Reports.add_comment(section.id, owner.id, "Fix this", "user")

      actions = [
        %{"action" => "add", "path" => "Intro", "body" => "Working on it"},
        %{"action" => "resolve", "comment_id" => comment.id, "body" => "Done now"}
      ]

      assert {:ok, results} = Reports.manage_comments(report.id, owner.id, actions)
      assert length(results) == 2
    end

    test "add to non-existent section rolls back", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [%{"action" => "add", "path" => "Ghost", "body" => "Nope"}]
      assert {:error, :section_not_found} = Reports.manage_comments(report.id, owner.id, actions)
    end

    test "resolve non-existent comment rolls back", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      actions = [
        %{"action" => "resolve", "comment_id" => Ecto.UUID.generate(), "body" => "reply"}
      ]

      assert {:error, :comment_not_found} =
               Reports.manage_comments(report.id, owner.id, actions)
    end

    test "missing action returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      actions = [%{"path" => "X", "body" => "Y"}]
      assert {:error, :missing_action} = Reports.manage_comments(report.id, owner.id, actions)
    end

    test "unknown action returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      actions = [%{"action" => "bogus"}]
      assert {:error, :unknown_action} = Reports.manage_comments(report.id, owner.id, actions)
    end

    test "missing body for add returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      actions = [%{"action" => "add", "path" => "Intro"}]
      assert {:error, :missing_body} = Reports.manage_comments(report.id, owner.id, actions)
    end

    test "missing comment_id for resolve returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      actions = [%{"action" => "resolve", "body" => "reply"}]
      assert {:error, :missing_comment_id} = Reports.manage_comments(report.id, owner.id, actions)
    end

    test "missing body for resolve returns error", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, comment} = Reports.add_comment(section.id, owner.id, "Fix", "user")
      actions = [%{"action" => "resolve", "comment_id" => comment.id}]
      assert {:error, :missing_body} = Reports.manage_comments(report.id, owner.id, actions)
    end

    test "add with empty path creates report-level comment", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      actions = [%{"action" => "add", "path" => "", "body" => "Report note"}]
      assert {:ok, [result]} = Reports.manage_comments(report.id, owner.id, actions)
      assert result.action == "add"
      assert result.path == ""
      assert result.comment_id != nil
    end

    test "add with no path key creates report-level comment", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      actions = [%{"action" => "add", "body" => "Report note"}]
      assert {:ok, [result]} = Reports.manage_comments(report.id, owner.id, actions)
      assert result.action == "add"
      assert result.path == ""
    end

    test "accepts atom keys", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")

      actions = [%{action: "add", path: "Intro", body: "Note"}]
      assert {:ok, [result]} = Reports.manage_comments(report.id, owner.id, actions)
      assert result.action == "add"
    end

    test "unauthorized user returns not_found", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      actions = [%{"action" => "add", "path" => "X", "body" => "Y"}]
      assert {:error, :not_found} = Reports.manage_comments(report.id, other.id, actions)
    end
  end

  describe "get_report_comments/2" do
    test "returns report-level comments", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.add_report_comment(report.id, owner.id, "Top level note", "user")

      assert {:ok, comments} = Reports.get_report_comments(report.id, owner.id)
      assert length(comments) == 1
      assert hd(comments).body == "Top level note"
      assert hd(comments).section_id == nil
    end

    test "does not include section-level comments", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, _} = Reports.add_comment(section.id, owner.id, "Section note", "agent")
      {:ok, _} = Reports.add_report_comment(report.id, owner.id, "Report note", "user")

      assert {:ok, comments} = Reports.get_report_comments(report.id, owner.id)
      assert length(comments) == 1
      assert hd(comments).body == "Report note"
    end

    test "returns not_found for unauthorized user", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      assert {:error, :not_found} = Reports.get_report_comments(report.id, other.id)
    end
  end

  describe "add_report_comment/4" do
    test "creates report-level comment", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      assert {:ok, comment} =
               Reports.add_report_comment(report.id, owner.id, "General note", "user")

      assert comment.body == "General note"
      assert comment.author_type == "user"
      assert comment.report_id == report.id
      assert comment.section_id == nil
    end

    test "rejects invalid author_type", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      assert {:error, :invalid_author_type} =
               Reports.add_report_comment(report.id, owner.id, "Bad", "robot")
    end

    test "returns not_found for unauthorized user", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")

      assert {:error, :not_found} =
               Reports.add_report_comment(report.id, other.id, "Nope", "user")
    end
  end

  describe "section_tree/1" do
    test "returns tree structure with comments", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Intro", "Hello")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro > Details", "Nested")
      {:ok, _} = Reports.add_comment(section.id, owner.id, "Expand this", "user")

      {:ok, report} = Reports.get_report(report.id, owner.id)
      tree = Reports.section_tree(report)

      assert length(tree) == 1
      node = hd(tree)
      assert node.section.title == "Intro"
      assert length(node.children) == 1
      child = hd(node.children)
      assert child.section.title == "Details"
      assert length(child.section.comments) == 1
    end

    test "returns empty list for report with no sections", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, report} = Reports.get_report(report.id, owner.id)
      assert Reports.section_tree(report) == []
    end
  end

  describe "resolve_comment/3 for report-level comments" do
    test "resolves report-level comment with reply", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, comment} = Reports.add_report_comment(report.id, owner.id, "Fix overall", "user")

      assert {:ok, resolved} = Reports.resolve_comment(comment.id, owner.id, "All fixed")
      assert resolved.status == "addressed"
    end

    test "unauthorized user cannot resolve report-level comment", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, comment} = Reports.add_report_comment(report.id, owner.id, "Fix overall", "user")

      assert {:error, :not_found} = Reports.resolve_comment(comment.id, other.id, "reply")
    end
  end

  describe "reply_to_comment/4" do
    test "creates a reply to a section comment", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Content")
      {:ok, comment} = Reports.add_comment(section.id, owner.id, "Question?", "agent")

      assert {:ok, reply} = Reports.reply_to_comment(comment.id, owner.id, "Answer!", "user")
      assert reply.parent_comment_id == comment.id
      assert reply.body == "Answer!"
      assert reply.author_type == "user"
      assert reply.report_id == report.id
      assert reply.section_id == section.id
    end

    test "creates a reply to a report-level comment", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, comment} = Reports.add_report_comment(report.id, owner.id, "General note", "agent")

      assert {:ok, reply} = Reports.reply_to_comment(comment.id, owner.id, "Noted", "user")
      assert reply.parent_comment_id == comment.id
      assert reply.section_id == nil
      assert reply.report_id == report.id
    end

    test "rejects invalid author_type", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, comment} = Reports.add_report_comment(report.id, owner.id, "Note", "user")

      assert {:error, :invalid_author_type} =
               Reports.reply_to_comment(comment.id, owner.id, "Bad", "robot")
    end

    test "returns not_found for non-existent comment", %{owner: owner} do
      assert {:error, :not_found} =
               Reports.reply_to_comment(Ecto.UUID.generate(), owner.id, "Hello", "user")
    end

    test "unauthorized user cannot reply", %{owner: owner, other: other} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, comment} = Reports.add_report_comment(report.id, owner.id, "Note", "user")

      assert {:error, :not_found} =
               Reports.reply_to_comment(comment.id, other.id, "Nope", "user")
    end
  end

  describe "render_markdown with comments" do
    test "renders comments as blockquotes", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Hello")
      {:ok, _} = Reports.add_comment(section.id, owner.id, "Needs more detail", "user")
      {:ok, _} = Reports.add_comment(section.id, owner.id, "Agreed, expanding", "agent")

      {:ok, report} = Reports.get_report(report.id, owner.id)
      md = Reports.render_markdown(report)

      assert md =~ "# Intro"
      assert md =~ "Hello"
      assert md =~ "[USER]"
      assert md =~ "[OPEN]"
      assert md =~ "Needs more detail"
      assert md =~ "[AGENT]"
      assert md =~ "Agreed, expanding"
    end

    test "renders addressed comment status with reply", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Hello")
      {:ok, comment} = Reports.add_comment(section.id, owner.id, "Fix typo", "user")
      {:ok, _} = Reports.resolve_comment(comment.id, owner.id, "Fixed the typo")

      {:ok, report} = Reports.get_report(report.id, owner.id)
      md = Reports.render_markdown(report)
      assert md =~ "[ADDRESSED]"
      assert md =~ "(reply)"
      assert md =~ "Fixed the typo"
    end

    test "section with no comments renders without blockquotes", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Intro", "Hello")

      {:ok, report} = Reports.get_report(report.id, owner.id)
      md = Reports.render_markdown(report)
      refute md =~ ">"
    end

    test "report-level comments render at the top", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, _} = Reports.add_report_comment(report.id, owner.id, "Overall feedback", "user")
      {:ok, _} = Reports.upsert_section(report.id, owner.id, "Intro", "Hello")

      {:ok, report} = Reports.get_report(report.id, owner.id)
      md = Reports.render_markdown(report)
      assert md =~ "Overall feedback"
      assert md =~ "[USER]"

      # Report-level comments appear before section content
      feedback_pos = :binary.match(md, "Overall feedback") |> elem(0)
      intro_pos = :binary.match(md, "# Intro") |> elem(0)
      assert feedback_pos < intro_pos
    end

    test "render_markdown with include_comments: false omits comments", %{owner: owner} do
      {:ok, report} = Reports.create_report(owner.id, "Test")
      {:ok, section} = Reports.upsert_section(report.id, owner.id, "Intro", "Hello")
      {:ok, _} = Reports.add_comment(section.id, owner.id, "A comment", "user")
      {:ok, _} = Reports.add_report_comment(report.id, owner.id, "Report note", "user")

      {:ok, report} = Reports.get_report(report.id, owner.id)
      md = Reports.render_markdown(report, include_comments: false)

      assert md =~ "# Intro"
      assert md =~ "Hello"
      refute md =~ "A comment"
      refute md =~ "Report note"
    end
  end
end

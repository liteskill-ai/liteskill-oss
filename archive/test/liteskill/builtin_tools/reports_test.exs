defmodule Liteskill.BuiltinTools.ReportsTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.BuiltinTools.Reports, as: ReportsTool
  alias Liteskill.Reports.Report

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "tool-user-#{System.unique_integer([:positive])}@example.com",
        name: "Tool User",
        oidc_sub: "tool-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  test "id/0 returns reports" do
    assert ReportsTool.id() == "reports"
  end

  test "name/0 returns Reports" do
    assert ReportsTool.name() == "Reports"
  end

  test "description/0 returns a string" do
    assert is_binary(ReportsTool.description())
  end

  test "list_tools/0 returns tool definitions" do
    tools = ReportsTool.list_tools()
    assert length(tools) == 6
    names = Enum.map(tools, & &1["name"])
    assert "reports__create" in names
    assert "reports__list" in names
    assert "reports__get" in names
    assert "reports__modify_sections" in names
    assert "reports__comment" in names
    assert "reports__delete" in names
  end

  describe "call_tool/3" do
    test "create and list flow", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Test"}, ctx)
      data = decode_content(result)
      assert data["title"] == "Test"
      report_id = data["id"]

      assert {:ok, result} = ReportsTool.call_tool("reports__list", %{}, ctx)
      data = decode_content(result)
      ids = Enum.map(data["reports"], & &1["id"])
      assert report_id in ids
    end

    test "create with run_id in context", %{user: user} do
      {:ok, run} =
        Liteskill.Runs.create_run(%{
          name: "Tool Run #{System.unique_integer([:positive])}",
          prompt: "Test",
          user_id: user.id
        })

      ctx = [user_id: user.id, run_id: run.id]

      assert {:ok, result} =
               ReportsTool.call_tool("reports__create", %{"title" => "Run Report"}, ctx)

      data = decode_content(result)
      report = Liteskill.Repo.get!(Report, data["id"])
      assert report.run_id == run.id
    end

    test "create without run_id in context leaves run_id nil", %{user: user} do
      ctx = [user_id: user.id]

      assert {:ok, result} =
               ReportsTool.call_tool("reports__create", %{"title" => "User Report"}, ctx)

      data = decode_content(result)
      report = Liteskill.Repo.get!(Report, data["id"])
      assert report.run_id == nil
    end

    test "modify_sections upsert and get flow", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Test"}, ctx)
      report_id = decode_content(result)["id"]

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__modify_sections",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "upsert", "path" => "Introduction", "content" => "Hello world"},
              %{
                "action" => "upsert",
                "path" => "Findings > Key Points",
                "content" => "Important stuff"
              }
            ]
          },
          ctx
        )

      data = decode_content(result)
      assert length(data["results"]) == 2
      assert Enum.any?(data["results"], &(&1["path"] == "Introduction"))
      assert Enum.any?(data["results"], &(&1["path"] == "Findings > Key Points"))

      {:ok, result} =
        ReportsTool.call_tool("reports__get", %{"report_id" => report_id}, ctx)

      md = extract_text(result)
      assert md =~ "# Test"
      assert md =~ "## Introduction"
      assert md =~ "Hello world"
      assert md =~ "### Key Points"
      assert md =~ "Important stuff"
    end

    test "modify_sections delete flow", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Test"}, ctx)
      report_id = decode_content(result)["id"]

      {:ok, _} =
        ReportsTool.call_tool(
          "reports__modify_sections",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "upsert", "path" => "Temp", "content" => "Remove me"}
            ]
          },
          ctx
        )

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__modify_sections",
          %{
            "report_id" => report_id,
            "actions" => [%{"action" => "delete", "path" => "Temp"}]
          },
          ctx
        )

      data = decode_content(result)
      assert hd(data["results"])["action"] == "delete"
    end

    test "comment add flow", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Test"}, ctx)
      report_id = decode_content(result)["id"]

      {:ok, _} =
        ReportsTool.call_tool(
          "reports__modify_sections",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "upsert", "path" => "Intro", "content" => "Hello"}
            ]
          },
          ctx
        )

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__comment",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "add", "path" => "Intro", "body" => "Needs more detail"}
            ]
          },
          ctx
        )

      data = decode_content(result)
      assert length(data["results"]) == 1
      assert hd(data["results"])["action"] == "add"
      assert hd(data["results"])["comment_id"]
    end

    test "comment resolve flow", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Test"}, ctx)
      report_id = decode_content(result)["id"]

      {:ok, _} =
        ReportsTool.call_tool(
          "reports__modify_sections",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "upsert", "path" => "Intro", "content" => "Hello"}
            ]
          },
          ctx
        )

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__comment",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "add", "path" => "Intro", "body" => "Fix this"}
            ]
          },
          ctx
        )

      comment_id = hd(decode_content(result)["results"])["comment_id"]

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__comment",
          %{
            "report_id" => report_id,
            "actions" => [
              %{
                "action" => "resolve",
                "comment_id" => comment_id,
                "body" => "Fixed the issue"
              }
            ]
          },
          ctx
        )

      data = decode_content(result)
      assert hd(data["results"])["action"] == "resolve"
      assert hd(data["results"])["reply_id"]
    end

    test "comment resolve without body returns error", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Test"}, ctx)
      report_id = decode_content(result)["id"]

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__comment",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "resolve", "comment_id" => Ecto.UUID.generate()}
            ]
          },
          ctx
        )

      assert decode_content(result)["error"] == "missing_body"
    end

    test "comments appear in reports__get markdown", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Test"}, ctx)
      report_id = decode_content(result)["id"]

      {:ok, _} =
        ReportsTool.call_tool(
          "reports__modify_sections",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "upsert", "path" => "Intro", "content" => "Hello world"}
            ]
          },
          ctx
        )

      {:ok, _} =
        ReportsTool.call_tool(
          "reports__comment",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "add", "path" => "Intro", "body" => "Needs improvement"}
            ]
          },
          ctx
        )

      {:ok, result} =
        ReportsTool.call_tool("reports__get", %{"report_id" => report_id}, ctx)

      md = extract_text(result)
      assert md =~ "Needs improvement"
      assert md =~ "[AGENT]"
      assert md =~ "id:"
    end

    test "report-level comment (empty path)", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Test"}, ctx)
      report_id = decode_content(result)["id"]

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__comment",
          %{
            "report_id" => report_id,
            "actions" => [
              %{"action" => "add", "body" => "Report-level note"}
            ]
          },
          ctx
        )

      data = decode_content(result)
      assert length(data["results"]) == 1
      assert hd(data["results"])["action"] == "add"
      assert hd(data["results"])["path"] == ""

      # Verify it appears in the markdown output
      {:ok, result} =
        ReportsTool.call_tool("reports__get", %{"report_id" => report_id}, ctx)

      md = extract_text(result)
      assert md =~ "Report-level note"
    end

    test "delete", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{"title" => "Delete me"}, ctx)
      report_id = decode_content(result)["id"]

      {:ok, result} =
        ReportsTool.call_tool("reports__delete", %{"report_id" => report_id}, ctx)

      assert decode_content(result)["deleted"] == true
    end

    test "unknown tool returns error", %{user: user} do
      {:ok, result} = ReportsTool.call_tool("reports__unknown", %{}, user_id: user.id)
      data = decode_content(result)
      assert data["error"] =~ "Unknown tool"
    end

    test "get non-existent report returns error", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        ReportsTool.call_tool("reports__get", %{"report_id" => Ecto.UUID.generate()}, ctx)

      assert decode_content(result)["error"] == "not_found"
    end

    test "modify_sections on non-existent report returns error", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__modify_sections",
          %{
            "report_id" => Ecto.UUID.generate(),
            "actions" => [%{"action" => "upsert", "path" => "A", "content" => "B"}]
          },
          ctx
        )

      assert decode_content(result)["error"] == "not_found"
    end

    test "delete non-existent report returns error", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        ReportsTool.call_tool("reports__delete", %{"report_id" => Ecto.UUID.generate()}, ctx)

      assert decode_content(result)["error"]
    end

    test "comment on non-existent report returns error", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        ReportsTool.call_tool(
          "reports__comment",
          %{
            "report_id" => Ecto.UUID.generate(),
            "actions" => [%{"action" => "add", "path" => "Intro", "body" => "Hi"}]
          },
          ctx
        )

      assert decode_content(result)["error"] == "not_found"
    end

    test "missing required fields return error", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} = ReportsTool.call_tool("reports__create", %{}, ctx)
      assert decode_content(result)["error"]

      {:ok, result} = ReportsTool.call_tool("reports__get", %{}, ctx)
      assert decode_content(result)["error"]

      {:ok, result} = ReportsTool.call_tool("reports__modify_sections", %{}, ctx)
      assert decode_content(result)["error"]

      {:ok, result} = ReportsTool.call_tool("reports__comment", %{}, ctx)
      assert decode_content(result)["error"]

      {:ok, result} = ReportsTool.call_tool("reports__delete", %{}, ctx)
      assert decode_content(result)["error"]
    end
  end

  describe "RBAC error paths" do
    test "create with nil user_id returns forbidden" do
      {:ok, result} =
        ReportsTool.call_tool("reports__create", %{"title" => "x"}, user_id: nil)

      assert decode_content(result)["error"] =~ "forbidden"
    end
  end

  defp decode_content(%{"content" => [%{"text" => json}]}) do
    Jason.decode!(json)
  end

  defp extract_text(%{"content" => [%{"text" => text}]}), do: text
end

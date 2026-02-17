defmodule Liteskill.BuiltinTools.WikiTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.BuiltinTools.Wiki, as: WikiTool

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "wiki-tool-#{System.unique_integer([:positive])}@example.com",
        name: "Wiki Tool User",
        oidc_sub: "wiki-tool-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  test "id/0 returns wiki" do
    assert WikiTool.id() == "wiki"
  end

  test "name/0 returns Wiki" do
    assert WikiTool.name() == "Wiki"
  end

  test "description/0 returns a string" do
    assert is_binary(WikiTool.description())
  end

  test "list_tools/0 returns two tool definitions" do
    tools = WikiTool.list_tools()
    assert length(tools) == 2
    names = Enum.map(tools, & &1["name"])
    assert "wiki__read" in names
    assert "wiki__write" in names
  end

  describe "wiki__read spaces mode" do
    test "lists accessible spaces", %{user: user} do
      ctx = [user_id: user.id]

      # Create a space first
      {:ok, _} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "My Space"}]},
          ctx
        )

      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "spaces"}, ctx)

      data = decode_content(result)
      assert is_list(data["spaces"])
      assert data["spaces"] != []

      space = Enum.find(data["spaces"], &(&1["title"] == "My Space"))
      assert space
      assert space["role"] == "owner"
      assert is_integer(space["article_count"])
      assert space["updated_at"]
    end
  end

  describe "wiki__read tree mode" do
    test "returns article tree for a space", %{user: user} do
      ctx = [user_id: user.id]

      # Create space
      {:ok, write_result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Tree Space"}]},
          ctx
        )

      space_id = hd(decode_content(write_result)["results"])["id"]

      # Create an article under the space
      {:ok, _} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "create_article",
                "parent_id" => space_id,
                "title" => "First Article"
              }
            ]
          },
          ctx
        )

      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "tree", "space_id" => space_id}, ctx)

      data = decode_content(result)
      assert data["space"]["id"] == space_id
      assert data["space"]["title"] == "Tree Space"
      assert is_list(data["articles"])
      assert length(data["articles"]) == 1
      assert hd(data["articles"])["title"] == "First Article"
      assert is_list(hd(data["articles"])["children"])
    end

    test "returns error for non-existent space", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__read",
          %{"mode" => "tree", "space_id" => Ecto.UUID.generate()},
          ctx
        )

      assert decode_content(result)["error"] == "not_found"
    end

    test "returns error when space_id is missing", %{user: user} do
      {:ok, result} = WikiTool.call_tool("wiki__read", %{"mode" => "tree"}, user_id: user.id)
      assert decode_content(result)["error"] != nil
    end
  end

  describe "wiki__read articles mode" do
    test "reads article content by IDs", %{user: user} do
      ctx = [user_id: user.id]

      # Create space and article
      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "create_space",
                "title" => "Read Space",
                "content" => "Line 1\nLine 2\nLine 3"
              }
            ]
          },
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "articles", "ids" => [space_id]}, ctx)

      data = decode_content(result)
      assert length(data["articles"]) == 1
      article = hd(data["articles"])
      assert article["id"] == space_id
      assert article["title"] == "Read Space"
      assert article["content"] =~ "Line 1"
      assert article["total_lines"] == 3
    end

    test "reads articles with line ranges", %{user: user} do
      ctx = [user_id: user.id]

      content = Enum.map_join(1..20, "\n", fn i -> "Line number #{i}" end)

      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "create_space", "title" => "Range Space", "content" => content}
            ]
          },
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__read",
          %{
            "mode" => "articles",
            "ids" => [space_id],
            "ranges" => %{space_id => %{"start" => 5, "end" => 10}}
          },
          ctx
        )

      data = decode_content(result)
      article = hd(data["articles"])
      assert article["total_lines"] == 20
      assert article["range"] == [5, 10]
      assert article["content"] =~ "5: Line number 5"
      assert article["content"] =~ "10: Line number 10"
      refute article["content"] =~ "4: Line number 4"
    end

    test "returns error for non-existent article ID", %{user: user} do
      ctx = [user_id: user.id]
      fake_id = Ecto.UUID.generate()

      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "articles", "ids" => [fake_id]}, ctx)

      data = decode_content(result)
      assert hd(data["articles"])["error"] == "not_found"
    end

    test "returns error when ids is missing", %{user: user} do
      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "articles"}, user_id: user.id)

      assert decode_content(result)["error"] != nil
    end
  end

  describe "wiki__read search mode" do
    test "searches across wiki content", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, _} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "create_space",
                "title" => "Searchable Space",
                "content" => "unique_keyword_for_search"
              }
            ]
          },
          ctx
        )

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__read",
          %{"mode" => "search", "query" => "unique_keyword_for_search"},
          ctx
        )

      data = decode_content(result)
      assert is_list(data["results"])
      assert data["total"] >= 1
      assert data["page"] == 1
    end

    test "search with page param", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__read",
          %{"mode" => "search", "query" => "nonexistent_xyz", "page" => 2},
          ctx
        )

      data = decode_content(result)
      assert data["page"] == 2
      assert data["total"] == 0
    end

    test "search with space_id filter", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Filtered Space"}]},
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__read",
          %{"mode" => "search", "query" => "Filtered", "space_id" => space_id},
          ctx
        )

      data = decode_content(result)
      assert is_list(data["results"])
    end

    test "returns error when query is missing", %{user: user} do
      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "search"}, user_id: user.id)

      assert decode_content(result)["error"] != nil
    end
  end

  describe "wiki__read invalid mode" do
    test "returns error for missing mode", %{user: user} do
      {:ok, result} = WikiTool.call_tool("wiki__read", %{}, user_id: user.id)
      assert decode_content(result)["error"] != nil
    end

    test "returns error for invalid mode", %{user: user} do
      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "bogus"}, user_id: user.id)

      assert decode_content(result)["error"] != nil
    end
  end

  describe "wiki__write create_space" do
    test "creates a wiki space", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "create_space", "title" => "New Space", "content" => "Hello"}
            ]
          },
          ctx
        )

      data = decode_content(result)
      assert length(data["results"]) == 1
      r = hd(data["results"])
      assert r["status"] == "ok"
      assert r["action"] == "create_space"
      assert r["title"] == "New Space"
      assert r["id"]
    end

    test "creates a space with description", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "create_space",
                "title" => "Described Space",
                "description" => "A space with a description"
              }
            ]
          },
          ctx
        )

      data = decode_content(result)
      r = hd(data["results"])
      assert r["status"] == "ok"
      assert r["title"] == "Described Space"
    end

    test "returns error for duplicate space title (slug conflict)", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, _} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Duplicate Title"}]},
          ctx
        )

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Duplicate Title"}]},
          ctx
        )

      data = decode_content(result)
      r = hd(data["results"])
      assert r["status"] == "error"
    end

    test "returns error when user lacks create permission" do
      ctx = [user_id: nil]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "create_space", "title" => "Forbidden Space"}
            ]
          },
          ctx
        )

      data = decode_content(result)
      r = hd(data["results"])
      assert r["status"] == "error"
      assert r["error"] == "you don't have permission"
    end

    test "returns error when title is missing", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space"}]},
          ctx
        )

      data = decode_content(result)
      assert hd(data["results"])["status"] == "error"
      assert hd(data["results"])["error"] == "missing title"
    end
  end

  describe "wiki__write create_article" do
    test "creates an article under a space", %{user: user} do
      ctx = [user_id: user.id]

      # Create parent space
      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Parent Space"}]},
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "create_article",
                "parent_id" => space_id,
                "title" => "Child Article",
                "content" => "Article content"
              }
            ]
          },
          ctx
        )

      data = decode_content(result)
      r = hd(data["results"])
      assert r["status"] == "ok"
      assert r["title"] == "Child Article"
    end

    test "returns error for non-existent parent_id", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "create_article",
                "parent_id" => Ecto.UUID.generate(),
                "title" => "Orphaned Article"
              }
            ]
          },
          ctx
        )

      data = decode_content(result)
      r = hd(data["results"])
      assert r["status"] == "error"
    end

    test "returns error when parent_id or title is missing", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_article", "title" => "No Parent"}]},
          ctx
        )

      data = decode_content(result)
      assert hd(data["results"])["status"] == "error"
      assert hd(data["results"])["error"] =~ "missing"
    end
  end

  describe "wiki__write update" do
    test "updates an article", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "create_space", "title" => "Update Space", "content" => "Original"}
            ]
          },
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "update",
                "id" => space_id,
                "content" => "Updated content",
                "title" => "Updated Space"
              }
            ]
          },
          ctx
        )

      data = decode_content(result)
      r = hd(data["results"])
      assert r["status"] == "ok"
      assert r["title"] == "Updated Space"
    end

    test "returns error for non-existent id", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "update", "id" => Ecto.UUID.generate(), "content" => "x"}
            ]
          },
          ctx
        )

      data = decode_content(result)
      assert hd(data["results"])["status"] == "error"
    end

    test "returns error when id is missing", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "update", "content" => "x"}]},
          ctx
        )

      data = decode_content(result)
      assert hd(data["results"])["status"] == "error"
      assert hd(data["results"])["error"] == "missing id"
    end
  end

  describe "wiki__write delete" do
    test "deletes an article", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Delete Me"}]},
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "delete", "id" => space_id}]},
          ctx
        )

      data = decode_content(result)
      r = hd(data["results"])
      assert r["status"] == "ok"
      assert r["id"] == space_id
    end

    test "returns error for non-existent id", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "delete", "id" => Ecto.UUID.generate()}]},
          ctx
        )

      data = decode_content(result)
      assert hd(data["results"])["status"] == "error"
    end

    test "returns error when id is missing", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "delete"}]},
          ctx
        )

      data = decode_content(result)
      assert hd(data["results"])["status"] == "error"
      assert hd(data["results"])["error"] == "missing id"
    end
  end

  describe "wiki__write batch operations" do
    test "mixed actions with successes and failures", %{user: user} do
      ctx = [user_id: user.id]

      # Create a space first
      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Batch Space"}]},
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      # Batch: create article (success) + delete non-existent (failure) + unknown action
      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "create_article",
                "parent_id" => space_id,
                "title" => "Batch Article"
              },
              %{"action" => "delete", "id" => Ecto.UUID.generate()},
              %{"action" => "unknown_action"}
            ]
          },
          ctx
        )

      data = decode_content(result)
      assert length(data["results"]) == 3

      assert Enum.at(data["results"], 0)["status"] == "ok"
      assert Enum.at(data["results"], 1)["status"] == "error"
      assert Enum.at(data["results"], 2)["status"] == "error"
      assert Enum.at(data["results"], 2)["error"] == "unknown action"
    end
  end

  describe "wiki__write missing actions" do
    test "returns error when actions field is missing", %{user: user} do
      {:ok, result} = WikiTool.call_tool("wiki__write", %{}, user_id: user.id)
      assert decode_content(result)["error"] != nil
    end
  end

  describe "ACL enforcement" do
    test "second user cannot read space they don't have access to", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Private Space"}]},
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      # Create second user
      {:ok, user2} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "wiki-other-#{System.unique_integer([:positive])}@example.com",
          name: "Other User",
          oidc_sub: "wiki-other-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      ctx2 = [user_id: user2.id]

      # User2 cannot read the article
      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "articles", "ids" => [space_id]}, ctx2)

      data = decode_content(result)
      assert hd(data["articles"])["error"] == "not_found"

      # User2 cannot see in tree
      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "tree", "space_id" => space_id}, ctx2)

      assert decode_content(result)["error"] == "not_found"
    end

    test "second user cannot update space they don't own", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Protected Space"}]},
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, user2} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "wiki-nowrite-#{System.unique_integer([:positive])}@example.com",
          name: "No Write User",
          oidc_sub: "wiki-nowrite-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      ctx2 = [user_id: user2.id]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "update", "id" => space_id, "content" => "Hacked"}
            ]
          },
          ctx2
        )

      data = decode_content(result)
      assert hd(data["results"])["status"] == "error"
    end
  end

  describe "unknown tool" do
    test "returns error for unknown tool name", %{user: user} do
      {:ok, result} = WikiTool.call_tool("wiki__unknown", %{}, user_id: user.id)
      data = decode_content(result)
      assert data["error"] =~ "Unknown tool"
    end
  end

  describe "article with nil content" do
    test "handles nil content gracefully", %{user: user} do
      ctx = [user_id: user.id]

      # Create space without content
      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Empty Space"}]},
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "articles", "ids" => [space_id]}, ctx)

      data = decode_content(result)
      article = hd(data["articles"])
      assert article["content"] == ""
      assert article["total_lines"] == 1
    end
  end

  describe "article with malformed range" do
    test "falls back to full content with malformed range", %{user: user} do
      ctx = [user_id: user.id]

      {:ok, wr} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "create_space", "title" => "Range Test", "content" => "Hello\nWorld"}
            ]
          },
          ctx
        )

      space_id = hd(decode_content(wr)["results"])["id"]

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__read",
          %{
            "mode" => "articles",
            "ids" => [space_id],
            "ranges" => %{space_id => %{"bad" => "format"}}
          },
          ctx
        )

      data = decode_content(result)
      article = hd(data["articles"])
      # Falls back to full content
      assert article["content"] =~ "Hello"
      assert article["total_lines"] == 2
    end
  end

  describe "search result snippet for nil content" do
    test "returns empty snippet for nil content", %{user: user} do
      ctx = [user_id: user.id]

      # Create space without content and search by title
      {:ok, _} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "create_space", "title" => "snippet_nil_content_test_xyz"}
            ]
          },
          ctx
        )

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__read",
          %{"mode" => "search", "query" => "snippet_nil_content_test_xyz"},
          ctx
        )

      data = decode_content(result)
      assert data["results"] != []
      found = Enum.find(data["results"], &(&1["title"] == "snippet_nil_content_test_xyz"))
      assert found["snippet"] == ""
    end
  end

  describe "wiki sync enqueuing from agent tool calls" do
    test "create_space with content enqueues wiki sync", %{user: user} do
      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "create_space", "title" => "Agent Space", "content" => "Hello world"}
            ]
          },
          user_id: user.id
        )

      data = decode_content(result)
      [%{"status" => "ok", "id" => space_id}] = data["results"]

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => space_id, "action" => "upsert"}
      )
    end

    test "create_article with content enqueues wiki sync", %{user: user} do
      {:ok, _} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Parent Space"}]},
          user_id: user.id
        )

      {:ok, space_result} =
        WikiTool.call_tool("wiki__read", %{"mode" => "spaces"}, user_id: user.id)

      space =
        decode_content(space_result)["spaces"] |> Enum.find(&(&1["title"] == "Parent Space"))

      {:ok, result} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{
                "action" => "create_article",
                "parent_id" => space["id"],
                "title" => "Agent Article",
                "content" => "Article content"
              }
            ]
          },
          user_id: user.id
        )

      data = decode_content(result)
      [%{"status" => "ok", "id" => article_id}] = data["results"]

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => article_id, "action" => "upsert"}
      )
    end

    test "update with content enqueues wiki sync", %{user: user} do
      {:ok, create_result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Update Space"}]},
          user_id: user.id
        )

      [%{"id" => space_id}] = decode_content(create_result)["results"]

      {:ok, _} =
        WikiTool.call_tool(
          "wiki__write",
          %{
            "actions" => [
              %{"action" => "update", "id" => space_id, "content" => "Updated content"}
            ]
          },
          user_id: user.id
        )

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => space_id, "action" => "upsert"}
      )
    end

    test "delete enqueues wiki sync delete", %{user: user} do
      {:ok, create_result} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "create_space", "title" => "Delete Space"}]},
          user_id: user.id
        )

      [%{"id" => space_id}] = decode_content(create_result)["results"]

      {:ok, _} =
        WikiTool.call_tool(
          "wiki__write",
          %{"actions" => [%{"action" => "delete", "id" => space_id}]},
          user_id: user.id
        )

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => space_id, "action" => "delete"}
      )
    end
  end

  defp decode_content(%{"content" => [%{"text" => json}]}) do
    Jason.decode!(json)
  end
end

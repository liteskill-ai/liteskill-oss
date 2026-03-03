defmodule LiteskillWeb.WikiExportControllerTest do
  use LiteskillWeb.ConnCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.DataSources

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "export-ctrl-#{System.unique_integer([:positive])}@example.com",
        name: "Export Controller Tester",
        oidc_sub: "export-ctrl-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    conn = init_authenticated_session(build_conn(), user)

    %{conn: conn, user: user}
  end

  describe "export/2" do
    test "returns ZIP for a valid space", %{conn: conn, user: user} do
      {:ok, space} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Export Space", content: "Root"},
          user.id
        )

      {:ok, _child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child", content: "Body"},
          user.id
        )

      conn = get(conn, ~p"/wiki/#{space.id}/export")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/zip"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ".zip"

      # Verify it's a valid ZIP
      {:ok, file_list} = :zip.unzip(conn.resp_body, [:memory])
      paths = Enum.map(file_list, fn {path, _} -> to_string(path) end)
      assert "manifest.json" in paths
    end

    test "returns 404 for nonexistent space", %{conn: conn} do
      conn = get(conn, ~p"/wiki/#{Ecto.UUID.generate()}/export")

      assert json_response(conn, 404)["error"] == "not found"
    end

    test "returns 401 for unauthenticated request" do
      {:ok, user} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "anon-#{System.unique_integer([:positive])}@example.com",
          name: "Anon",
          oidc_sub: "anon-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Private", content: ""}, user.id)

      conn =
        build_conn()
        |> init_test_session(%{})
        |> get(~p"/wiki/#{space.id}/export")

      assert json_response(conn, 401)["error"] == "authentication required"
    end
  end
end

defmodule LiteskillWeb.WikiExportController do
  @moduledoc false
  use LiteskillWeb, :controller

  alias Liteskill.DataSources.WikiExport
  alias LiteskillWeb.Plugs.Auth

  def export(conn, %{"space_id" => space_id}) do
    conn = Auth.fetch_current_user(conn)

    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "authentication required"})

      user ->
        case WikiExport.export_space(space_id, user.id) do
          {:ok, {filename, zip_binary}} ->
            conn
            |> put_resp_content_type("application/zip")
            |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
            |> send_resp(200, zip_binary)

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "not found"})
        end
    end
  end
end

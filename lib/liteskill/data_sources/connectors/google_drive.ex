defmodule Liteskill.DataSources.Connectors.GoogleDrive do
  @moduledoc """
  Connector for Google Drive sources.

  Uses a service account for authentication. The service account JSON and
  folder ID are stored in the source's encrypted metadata.

  Supports:
  - Google Docs → exported as text/plain
  - Google Sheets → exported as text/csv
  - Google Slides → exported as text/plain
  - Text/Markdown/Code files → downloaded directly
  - JSON files → downloaded directly
  - Unsupported types (PDF, images, etc.) → skipped
  """

  @behaviour Liteskill.DataSources.Connector

  @drive_base "https://www.googleapis.com/drive/v3"
  @token_url "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/drive.readonly"

  @google_doc "application/vnd.google-apps.document"
  @google_sheet "application/vnd.google-apps.spreadsheet"
  @google_slides "application/vnd.google-apps.presentation"
  @google_folder "application/vnd.google-apps.folder"

  @impl true
  def source_type, do: "google_drive"

  @impl true
  def validate_connection(source, opts) do
    with {:ok, token} <- get_access_token(source, opts) do
      folder_id = get_folder_id(source)
      req_opts = req_opts(opts)

      case Req.get(
             new_req(15_000),
             [
               url: "#{@drive_base}/files",
               headers: [{"authorization", "Bearer #{token}"}],
               params:
                 shared_drive_params(%{
                   "q" => "'#{folder_id}' in parents and trashed = false",
                   "pageSize" => "1",
                   "fields" => "files(id)"
                 })
             ] ++ req_opts
           ) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
        # coveralls-ignore-next-line
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list_entries(source, cursor, opts) do
    with {:ok, token} <- get_access_token(source, opts) do
      folder_id = get_folder_id(source)
      req_opts = req_opts(opts)

      params =
        %{
          "q" => "'#{folder_id}' in parents and trashed = false",
          "pageSize" => "100",
          "fields" => "nextPageToken,files(id,name,mimeType,md5Checksum,modifiedTime)"
        }
        |> shared_drive_params()
        |> maybe_put_cursor(cursor)

      case Req.get(
             new_req(30_000),
             [
               url: "#{@drive_base}/files",
               headers: [{"authorization", "Bearer #{token}"}],
               params: params
             ] ++ req_opts
           ) do
        {:ok, %{status: 200, body: body}} ->
          next_cursor = body["nextPageToken"]

          entries =
            (body["files"] || [])
            |> Enum.reject(&(&1["mimeType"] == @google_folder))
            |> Enum.map(&file_to_entry/1)

          {:ok, %{entries: entries, next_cursor: next_cursor, has_more: next_cursor != nil}}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        # coveralls-ignore-next-line
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def fetch_content(source, external_id, opts) do
    with {:ok, token} <- get_access_token(source, opts) do
      # We need the file's mimeType to decide how to fetch content.
      # First get file metadata, then fetch/export accordingly.
      req_opts = req_opts(opts)

      case get_file_metadata(external_id, token, req_opts) do
        {:ok, file} ->
          fetch_file_content(file, token, req_opts)

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Fetches folder/drive metadata to build a human-readable description.
  Returns {:ok, description} or {:error, reason}.
  """
  def describe_folder(source, opts) do
    with {:ok, token} <- get_access_token(source, opts) do
      folder_id = get_folder_id(source)
      req_opts = req_opts(opts)

      case Req.get(
             new_req(15_000),
             [
               url: "#{@drive_base}/files/#{folder_id}",
               headers: [{"authorization", "Bearer #{token}"}],
               params: %{"fields" => "id,name,mimeType,driveId", "supportsAllDrives" => "true"}
             ] ++ req_opts
           ) do
        {:ok, %{status: 200, body: body}} ->
          folder_name = body["name"] || folder_id
          drive_id = body["driveId"]

          description =
            if drive_id do
              case get_drive_name(drive_id, token, req_opts) do
                {:ok, drive_name} -> "#{drive_name} / #{folder_name}"
                _ -> "Shared Drive / #{folder_name}"
              end
            else
              folder_name
            end

          {:ok, description}

        _ ->
          {:ok, "Folder #{folder_id}"}
      end
    end
  end

  defp get_drive_name(drive_id, token, req_opts) do
    case Req.get(
           new_req(15_000),
           [
             url: "#{@drive_base}/drives/#{drive_id}",
             headers: [{"authorization", "Bearer #{token}"}],
             params: %{"fields" => "id,name"}
           ] ++ req_opts
         ) do
      {:ok, %{status: 200, body: %{"name" => name}}} -> {:ok, name}
      _ -> {:error, :not_found}
    end
  end

  # --- Private: Auth ---

  defp get_access_token(source, opts) do
    with {:ok, sa} <- parse_service_account(source) do
      jwt = build_jwt(sa)
      exchange_token(jwt, opts)
    end
  end

  defp parse_service_account(source) do
    json_str = get_in(source.metadata || %{}, ["service_account_json"])

    case Jason.decode(json_str || "") do
      {:ok, %{"client_email" => email, "private_key" => key}} ->
        {:ok, %{client_email: email, private_key: key}}

      _ ->
        {:error, :invalid_service_account}
    end
  end

  defp build_jwt(%{client_email: email, private_key: pem_key}) do
    now = System.system_time(:second)

    claims = %{
      "iss" => email,
      "scope" => @scope,
      "aud" => @token_url,
      "iat" => now,
      "exp" => now + 3600
    }

    jwk = JOSE.JWK.from_pem(pem_key)
    jws = %{"alg" => "RS256"}
    {_, token} = jwk |> JOSE.JWT.sign(jws, claims) |> JOSE.JWS.compact()
    token
  end

  defp exchange_token(jwt, opts) do
    req_opts = req_opts(opts)

    case Req.post(
           new_req(15_000),
           [
             url: @token_url,
             form: [
               grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
               assertion: jwt
             ]
           ] ++ req_opts
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: Drive API ---

  defp get_file_metadata(file_id, token, req_opts) do
    case Req.get(
           new_req(15_000),
           [
             url: "#{@drive_base}/files/#{file_id}",
             headers: [{"authorization", "Bearer #{token}"}],
             params: %{
               "fields" => "id,name,mimeType,md5Checksum,modifiedTime",
               "supportsAllDrives" => "true"
             }
           ] ++ req_opts
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      # coveralls-ignore-next-line
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_file_content(file, token, req_opts) do
    mime = file["mimeType"]

    cond do
      mime == @google_doc ->
        export_file(file["id"], "text/plain", token, req_opts)

      mime == @google_sheet ->
        export_file(file["id"], "text/csv", token, req_opts)

      mime == @google_slides ->
        export_file(file["id"], "text/plain", token, req_opts)

      String.starts_with?(mime || "", "text/") ->
        download_file(file["id"], token, req_opts)

      mime == "application/json" ->
        download_file(file["id"], token, req_opts)

      true ->
        {:error, :unsupported_content_type}
    end
  end

  defp export_file(file_id, export_mime, token, req_opts) do
    case Req.get(
           new_req(30_000),
           [
             url: "#{@drive_base}/files/#{file_id}/export",
             headers: [{"authorization", "Bearer #{token}"}],
             params: %{"mimeType" => export_mime}
           ] ++ req_opts
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok,
         %{
           content: body,
           content_type: export_mime,
           content_hash: content_hash(body),
           metadata: %{}
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download_file(file_id, token, req_opts) do
    case Req.get(
           new_req(30_000),
           [
             url: "#{@drive_base}/files/#{file_id}",
             headers: [{"authorization", "Bearer #{token}"}],
             params: %{"alt" => "media"}
           ] ++ req_opts
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok,
         %{
           content: body,
           content_type: "text/plain",
           content_hash: content_hash(body),
           metadata: %{}
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: Helpers ---

  defp file_to_entry(file) do
    mime = file["mimeType"]

    %{
      external_id: file["id"],
      title: file["name"],
      content_type: normalize_content_type(mime),
      metadata: %{"mimeType" => mime, "modifiedTime" => file["modifiedTime"]},
      parent_external_id: nil,
      content_hash: file["md5Checksum"] || file["modifiedTime"],
      deleted: false
    }
  end

  defp normalize_content_type(@google_doc), do: "text/plain"
  defp normalize_content_type(@google_sheet), do: "text/csv"
  defp normalize_content_type(@google_slides), do: "text/plain"
  defp normalize_content_type(mime) when is_binary(mime), do: mime
  # coveralls-ignore-next-line
  defp normalize_content_type(_), do: "application/octet-stream"

  defp get_folder_id(source) do
    get_in(source.metadata || %{}, ["folder_id"]) || ""
  end

  defp shared_drive_params(params) do
    Map.merge(params, %{
      "supportsAllDrives" => "true",
      "includeItemsFromAllDrives" => "true"
    })
  end

  defp maybe_put_cursor(params, nil), do: params
  # coveralls-ignore-next-line
  defp maybe_put_cursor(params, cursor), do: Map.put(params, "pageToken", cursor)

  defp req_opts(opts) do
    if Keyword.get(opts, :plug, false) do
      [plug: {Req.Test, __MODULE__}]
    else
      []
    end
  end

  defp new_req(timeout), do: Req.new(receive_timeout: timeout, retry: false)

  # coveralls-ignore-next-line
  defp content_hash(nil), do: nil
  defp content_hash(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
end

defmodule Liteskill.DataSources.Connectors.GoogleDriveTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.DataSources
  alias Liteskill.DataSources.Connectors.GoogleDrive

  @test_folder_id "1AbC_dEfGhIjKlM"

  setup do
    # Generate a fresh RSA key for JWT signing in tests
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_type, pem} = JOSE.JWK.to_pem(jwk)

    sa_json =
      Jason.encode!(%{
        "type" => "service_account",
        "client_email" => "test@test-project.iam.gserviceaccount.com",
        "private_key" => pem,
        "token_uri" => "https://oauth2.googleapis.com/token"
      })

    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "gdrive-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "gdrive-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, source} =
      DataSources.create_source(
        %{name: "Test Drive", source_type: "google_drive"},
        owner.id
      )

    {:ok, source} =
      DataSources.update_source(
        source.id,
        %{metadata: %{"service_account_json" => sa_json, "folder_id" => @test_folder_id}},
        owner.id
      )

    %{owner: owner, source: source, sa_json: sa_json}
  end

  defp stub_google_api(responses) do
    token_response = Map.get(responses, :token, :ok)
    files_response = Map.get(responses, :files, :empty)
    export_response = Map.get(responses, :export, nil)
    download_response = Map.get(responses, :download, nil)
    metadata_response = Map.get(responses, :metadata, nil)
    drives_response = Map.get(responses, :drives, nil)

    Req.Test.stub(GoogleDrive, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          handle_token(conn, token_response)

        {"GET", "/drive/v3/files"} ->
          handle_files_list(conn, files_response)

        {"GET", "/drive/v3/drives/" <> _drive_id} ->
          handle_drives_get(conn, drives_response)

        {"GET", "/drive/v3/files/" <> rest} ->
          cond do
            String.contains?(rest, "/export") ->
              handle_export(conn, export_response)

            conn.query_params["alt"] == "media" ->
              handle_download(conn, download_response)

            true ->
              handle_file_metadata(conn, metadata_response)
          end
      end
    end)
  end

  defp handle_token(conn, :ok) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{"access_token" => "mock-token", "expires_in" => 3600})
    )
  end

  defp handle_token(conn, :error) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
  end

  defp handle_files_list(conn, :empty) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"files" => []}))
  end

  defp handle_files_list(conn, {:ok, body}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp handle_files_list(conn, {:error, status}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => %{"message" => "Not Found"}}))
  end

  defp handle_export(conn, {:ok, content}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, content)
  end

  defp handle_export(conn, {:error, status}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => %{"message" => "Export failed"}}))
  end

  defp handle_export(conn, nil) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, "default export content")
  end

  defp handle_download(conn, {:ok, content}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, content)
  end

  defp handle_download(conn, {:error, status}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => %{"message" => "Download failed"}}))
  end

  defp handle_download(conn, nil) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, "default download content")
  end

  defp handle_file_metadata(conn, {:ok, metadata}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(metadata))
  end

  defp handle_file_metadata(conn, {:error, status}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => %{"message" => "Not found"}}))
  end

  defp handle_file_metadata(conn, nil) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "id" => "file-1",
        "name" => "Default",
        "mimeType" => "text/plain",
        "md5Checksum" => "abc123"
      })
    )
  end

  defp handle_drives_get(conn, {:ok, drive_name}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "drive-1", "name" => drive_name}))
  end

  defp handle_drives_get(conn, _) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => %{"message" => "Not found"}}))
  end

  describe "source_type/0" do
    test "returns 'google_drive'" do
      assert "google_drive" == GoogleDrive.source_type()
    end
  end

  describe "validate_connection/2" do
    test "returns :ok with valid credentials", %{source: source} do
      stub_google_api(%{token: :ok, files: :empty})
      assert :ok = GoogleDrive.validate_connection(source, plug: true)
    end

    test "returns error when token exchange fails", %{source: source} do
      stub_google_api(%{token: :error})
      assert {:error, %{status: 401}} = GoogleDrive.validate_connection(source, plug: true)
    end

    test "returns error with invalid service account JSON", %{owner: owner} do
      {:ok, bad_source} =
        DataSources.create_source(
          %{name: "Bad Drive", source_type: "google_drive"},
          owner.id
        )

      {:ok, bad_source} =
        DataSources.update_source(
          bad_source.id,
          %{
            metadata: %{
              "service_account_json" => "not valid json",
              "folder_id" => @test_folder_id
            }
          },
          owner.id
        )

      assert {:error, :invalid_service_account} =
               GoogleDrive.validate_connection(bad_source, plug: true)
    end

    test "returns error with missing service account fields", %{owner: owner} do
      {:ok, bad_source} =
        DataSources.create_source(
          %{name: "Incomplete Drive", source_type: "google_drive"},
          owner.id
        )

      {:ok, bad_source} =
        DataSources.update_source(
          bad_source.id,
          %{
            metadata: %{
              "service_account_json" => Jason.encode!(%{"type" => "service_account"}),
              "folder_id" => @test_folder_id
            }
          },
          owner.id
        )

      assert {:error, :invalid_service_account} =
               GoogleDrive.validate_connection(bad_source, plug: true)
    end

    test "returns error when files.list fails", %{source: source} do
      stub_google_api(%{token: :ok, files: {:error, 404}})
      assert {:error, %{status: 404}} = GoogleDrive.validate_connection(source, plug: true)
    end
  end

  describe "list_entries/3" do
    test "returns file entries from Drive API", %{source: source, owner: owner} do
      files_body = %{
        "files" => [
          %{
            "id" => "file-1",
            "name" => "Document.txt",
            "mimeType" => "text/plain",
            "md5Checksum" => "abc123",
            "modifiedTime" => "2026-01-15T10:00:00.000Z"
          },
          %{
            "id" => "file-2",
            "name" => "My Doc",
            "mimeType" => "application/vnd.google-apps.document",
            "modifiedTime" => "2026-01-16T12:00:00.000Z"
          }
        ]
      }

      stub_google_api(%{token: :ok, files: {:ok, files_body}})

      {:ok, result} = GoogleDrive.list_entries(source, nil, user_id: owner.id, plug: true)

      assert result.has_more == false
      assert result.next_cursor == nil
      assert length(result.entries) == 2

      txt_entry = Enum.find(result.entries, &(&1.external_id == "file-1"))
      assert txt_entry.title == "Document.txt"
      assert txt_entry.content_type == "text/plain"
      assert txt_entry.content_hash == "abc123"
      assert txt_entry.deleted == false

      doc_entry = Enum.find(result.entries, &(&1.external_id == "file-2"))
      assert doc_entry.title == "My Doc"
      assert doc_entry.content_type == "text/plain"
      # Google Docs don't have md5, falls back to modifiedTime
      assert doc_entry.content_hash == "2026-01-16T12:00:00.000Z"
    end

    test "handles pagination with nextPageToken", %{source: source, owner: owner} do
      files_body = %{
        "nextPageToken" => "page2token",
        "files" => [
          %{
            "id" => "file-1",
            "name" => "Page 1 Doc",
            "mimeType" => "text/plain",
            "md5Checksum" => "hash1",
            "modifiedTime" => "2026-01-15T10:00:00.000Z"
          }
        ]
      }

      stub_google_api(%{token: :ok, files: {:ok, files_body}})

      {:ok, result} = GoogleDrive.list_entries(source, nil, user_id: owner.id, plug: true)

      assert result.has_more == true
      assert result.next_cursor == "page2token"
      assert length(result.entries) == 1
    end

    test "filters out folders", %{source: source, owner: owner} do
      files_body = %{
        "files" => [
          %{
            "id" => "folder-1",
            "name" => "My Folder",
            "mimeType" => "application/vnd.google-apps.folder",
            "modifiedTime" => "2026-01-15T10:00:00.000Z"
          },
          %{
            "id" => "file-1",
            "name" => "A File",
            "mimeType" => "text/plain",
            "md5Checksum" => "hash1",
            "modifiedTime" => "2026-01-15T10:00:00.000Z"
          }
        ]
      }

      stub_google_api(%{token: :ok, files: {:ok, files_body}})

      {:ok, result} = GoogleDrive.list_entries(source, nil, user_id: owner.id, plug: true)

      assert length(result.entries) == 1
      assert hd(result.entries).external_id == "file-1"
    end

    test "returns empty list for empty folder", %{source: source, owner: owner} do
      stub_google_api(%{token: :ok, files: :empty})

      {:ok, result} = GoogleDrive.list_entries(source, nil, user_id: owner.id, plug: true)

      assert result.entries == []
      assert result.has_more == false
    end

    test "returns error on API failure", %{source: source, owner: owner} do
      stub_google_api(%{token: :ok, files: {:error, 403}})

      assert {:error, %{status: 403}} =
               GoogleDrive.list_entries(source, nil, user_id: owner.id, plug: true)
    end

    test "returns error on auth failure", %{source: source, owner: owner} do
      stub_google_api(%{token: :error})

      assert {:error, %{status: 401}} =
               GoogleDrive.list_entries(source, nil, user_id: owner.id, plug: true)
    end

    test "normalizes Google Sheets and Slides MIME types in entries", %{
      source: source,
      owner: owner
    } do
      files_body = %{
        "files" => [
          %{
            "id" => "sheet-1",
            "name" => "Budget Spreadsheet",
            "mimeType" => "application/vnd.google-apps.spreadsheet",
            "modifiedTime" => "2026-01-20T09:00:00.000Z"
          },
          %{
            "id" => "slides-1",
            "name" => "Quarterly Deck",
            "mimeType" => "application/vnd.google-apps.presentation",
            "modifiedTime" => "2026-01-21T14:00:00.000Z"
          }
        ]
      }

      stub_google_api(%{token: :ok, files: {:ok, files_body}})

      {:ok, result} = GoogleDrive.list_entries(source, nil, user_id: owner.id, plug: true)

      assert length(result.entries) == 2

      sheet_entry = Enum.find(result.entries, &(&1.external_id == "sheet-1"))
      assert sheet_entry.title == "Budget Spreadsheet"
      assert sheet_entry.content_type == "text/csv"
      assert sheet_entry.content_hash == "2026-01-20T09:00:00.000Z"

      slides_entry = Enum.find(result.entries, &(&1.external_id == "slides-1"))
      assert slides_entry.title == "Quarterly Deck"
      assert slides_entry.content_type == "text/plain"
      assert slides_entry.content_hash == "2026-01-21T14:00:00.000Z"
    end
  end

  describe "fetch_content/3" do
    test "exports Google Doc as plain text", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "doc-1",
             "name" => "My Document",
             "mimeType" => "application/vnd.google-apps.document",
             "modifiedTime" => "2026-01-15T10:00:00.000Z"
           }},
        export: {:ok, "Hello from Google Docs"}
      })

      {:ok, result} = GoogleDrive.fetch_content(source, "doc-1", user_id: owner.id, plug: true)

      assert result.content == "Hello from Google Docs"
      assert result.content_type == "text/plain"
      assert is_binary(result.content_hash)
      assert is_map(result.metadata)
    end

    test "exports Google Sheet as CSV", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "sheet-1",
             "name" => "My Sheet",
             "mimeType" => "application/vnd.google-apps.spreadsheet",
             "modifiedTime" => "2026-01-15T10:00:00.000Z"
           }},
        export: {:ok, "col1,col2\nval1,val2"}
      })

      {:ok, result} = GoogleDrive.fetch_content(source, "sheet-1", user_id: owner.id, plug: true)

      assert result.content == "col1,col2\nval1,val2"
      assert result.content_type == "text/csv"
    end

    test "exports Google Slides as plain text", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "slides-1",
             "name" => "My Slides",
             "mimeType" => "application/vnd.google-apps.presentation",
             "modifiedTime" => "2026-01-15T10:00:00.000Z"
           }},
        export: {:ok, "Slide 1: Title\nSlide 2: Content"}
      })

      {:ok, result} =
        GoogleDrive.fetch_content(source, "slides-1", user_id: owner.id, plug: true)

      assert result.content == "Slide 1: Title\nSlide 2: Content"
      assert result.content_type == "text/plain"
    end

    test "downloads plain text file via alt=media", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "txt-1",
             "name" => "readme.txt",
             "mimeType" => "text/plain",
             "md5Checksum" => "abc123"
           }},
        download: {:ok, "Hello world from Drive"}
      })

      {:ok, result} = GoogleDrive.fetch_content(source, "txt-1", user_id: owner.id, plug: true)

      assert result.content == "Hello world from Drive"
      assert result.content_type == "text/plain"
      assert is_binary(result.content_hash)
    end

    test "downloads JSON file via alt=media", %{source: source, owner: owner} do
      json_content = ~s({"key": "value"})

      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "json-1",
             "name" => "data.json",
             "mimeType" => "application/json",
             "md5Checksum" => "def456"
           }},
        download: {:ok, json_content}
      })

      {:ok, result} = GoogleDrive.fetch_content(source, "json-1", user_id: owner.id, plug: true)

      assert result.content == json_content
    end

    test "returns unsupported error for PDF", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "pdf-1",
             "name" => "report.pdf",
             "mimeType" => "application/pdf",
             "md5Checksum" => "pdf123"
           }}
      })

      assert {:error, :unsupported_content_type} =
               GoogleDrive.fetch_content(source, "pdf-1", user_id: owner.id, plug: true)
    end

    test "returns unsupported error for image", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "img-1",
             "name" => "photo.png",
             "mimeType" => "image/png",
             "md5Checksum" => "img123"
           }}
      })

      assert {:error, :unsupported_content_type} =
               GoogleDrive.fetch_content(source, "img-1", user_id: owner.id, plug: true)
    end

    test "returns error for nonexistent file (404)", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata: {:error, 404}
      })

      assert {:error, %{status: 404}} =
               GoogleDrive.fetch_content(source, "nonexistent", user_id: owner.id, plug: true)
    end

    test "returns error on export failure", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "doc-fail",
             "name" => "Broken Doc",
             "mimeType" => "application/vnd.google-apps.document",
             "modifiedTime" => "2026-01-15T10:00:00.000Z"
           }},
        export: {:error, 500}
      })

      assert {:error, %{status: 500}} =
               GoogleDrive.fetch_content(source, "doc-fail", user_id: owner.id, plug: true)
    end

    test "returns error on download failure", %{source: source, owner: owner} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => "txt-fail",
             "name" => "broken.txt",
             "mimeType" => "text/plain",
             "md5Checksum" => "abc"
           }},
        download: {:error, 500}
      })

      assert {:error, %{status: 500}} =
               GoogleDrive.fetch_content(source, "txt-fail", user_id: owner.id, plug: true)
    end

    test "returns error on auth failure", %{source: source, owner: owner} do
      stub_google_api(%{token: :error})

      assert {:error, %{status: 401}} =
               GoogleDrive.fetch_content(source, "any-id", user_id: owner.id, plug: true)
    end
  end

  describe "describe_folder/2" do
    test "returns folder name with drive name for shared drive folder", %{source: source} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => @test_folder_id,
             "name" => "My Folder",
             "mimeType" => "application/vnd.google-apps.folder",
             "driveId" => "drive-123"
           }},
        drives: {:ok, "Team Drive"}
      })

      assert {:ok, "Team Drive / My Folder"} = GoogleDrive.describe_folder(source, plug: true)
    end

    test "falls back to 'Shared Drive' when drive name unavailable", %{source: source} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => @test_folder_id,
             "name" => "My Folder",
             "mimeType" => "application/vnd.google-apps.folder",
             "driveId" => "drive-123"
           }},
        drives: :not_found
      })

      assert {:ok, "Shared Drive / My Folder"} = GoogleDrive.describe_folder(source, plug: true)
    end

    test "returns folder name only for non-shared drive folder", %{source: source} do
      stub_google_api(%{
        token: :ok,
        metadata:
          {:ok,
           %{
             "id" => @test_folder_id,
             "name" => "My Personal Folder",
             "mimeType" => "application/vnd.google-apps.folder"
           }}
      })

      assert {:ok, "My Personal Folder"} = GoogleDrive.describe_folder(source, plug: true)
    end

    test "returns fallback on API error", %{source: source} do
      stub_google_api(%{token: :ok, metadata: {:error, 404}})

      assert {:ok, "Folder " <> _} = GoogleDrive.describe_folder(source, plug: true)
    end

    test "returns error on auth failure", %{source: source} do
      stub_google_api(%{token: :error})

      assert {:error, %{status: 401}} = GoogleDrive.describe_folder(source, plug: true)
    end
  end
end

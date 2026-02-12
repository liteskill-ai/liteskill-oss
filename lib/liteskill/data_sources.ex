defmodule Liteskill.DataSources do
  @moduledoc """
  Context for managing data sources and documents.

  Data sources can be either DB-backed (user-created) or built-in
  (defined in code, like Wiki). Documents are always in the DB.
  """

  alias Liteskill.DataSources.{Source, Document}
  alias Liteskill.Repo

  import Ecto.Query

  # --- Source Config Fields ---

  @source_config_fields %{
    "google_drive" => [
      %{
        key: "service_account_json",
        label: "Service Account JSON",
        placeholder: "Paste JSON key contents...",
        type: :textarea
      },
      %{
        key: "folder_id",
        label: "Folder / Drive ID",
        placeholder: "e.g. 1AbC_dEfGhIjKlM",
        type: :text
      }
    ],
    "sharepoint" => [
      %{
        key: "tenant_id",
        label: "Tenant ID",
        placeholder: "e.g. xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        type: :text
      },
      %{
        key: "site_url",
        label: "Site URL",
        placeholder: "https://yourorg.sharepoint.com/sites/...",
        type: :text
      },
      %{
        key: "client_id",
        label: "Client ID",
        placeholder: "Application (client) ID",
        type: :text
      },
      %{
        key: "client_secret",
        label: "Client Secret",
        placeholder: "Client secret value",
        type: :password
      }
    ],
    "confluence" => [
      %{
        key: "base_url",
        label: "Base URL",
        placeholder: "https://yourorg.atlassian.net/wiki",
        type: :text
      },
      %{key: "username", label: "Username / Email", placeholder: "user@example.com", type: :text},
      %{
        key: "api_token",
        label: "API Token",
        placeholder: "Atlassian API token",
        type: :password
      },
      %{key: "space_key", label: "Space Key", placeholder: "e.g. ENG", type: :text}
    ],
    "jira" => [
      %{
        key: "base_url",
        label: "Base URL",
        placeholder: "https://yourorg.atlassian.net",
        type: :text
      },
      %{key: "username", label: "Username / Email", placeholder: "user@example.com", type: :text},
      %{
        key: "api_token",
        label: "API Token",
        placeholder: "Atlassian API token",
        type: :password
      },
      %{key: "project_key", label: "Project Key", placeholder: "e.g. PROJ", type: :text}
    ],
    "github" => [
      %{
        key: "personal_access_token",
        label: "Personal Access Token",
        placeholder: "ghp_...",
        type: :password
      },
      %{key: "repository", label: "Repository", placeholder: "owner/repo", type: :text}
    ],
    "gitlab" => [
      %{
        key: "personal_access_token",
        label: "Personal Access Token",
        placeholder: "glpat-...",
        type: :password
      },
      %{key: "project_path", label: "Project Path", placeholder: "group/project", type: :text}
    ]
  }

  def config_fields_for(source_type), do: Map.get(@source_config_fields, source_type, [])

  @available_source_types [
    %{key: "google_drive", name: "Google Drive", source_type: "google_drive"},
    %{key: "sharepoint", name: "SharePoint", source_type: "sharepoint"},
    %{key: "confluence", name: "Confluence", source_type: "confluence"},
    %{key: "jira", name: "Jira", source_type: "jira"},
    %{key: "github", name: "GitHub", source_type: "github"},
    %{key: "gitlab", name: "GitLab", source_type: "gitlab"}
  ]

  def available_source_types, do: @available_source_types

  # --- Sources ---

  def list_sources(user_id) do
    db_sources =
      Source
      |> where([s], s.user_id == ^user_id)
      |> order_by([s], asc: s.name)
      |> Repo.all()

    Liteskill.BuiltinSources.virtual_sources() ++ db_sources
  end

  def get_source("builtin:" <> _ = id, _user_id) do
    case Liteskill.BuiltinSources.find(id) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end

  def get_source(id, user_id) do
    case Repo.get(Source, id) do
      nil -> {:error, :not_found}
      %Source{user_id: ^user_id} = source -> {:ok, source}
      _ -> {:error, :not_found}
    end
  end

  def create_source(attrs, user_id) do
    %Source{}
    |> Source.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  def update_source("builtin:" <> _, _attrs, _user_id), do: {:error, :cannot_update_builtin}

  def update_source(id, attrs, user_id) do
    with {:ok, source} <- get_source(id, user_id) do
      source
      |> Source.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_source("builtin:" <> _, _user_id), do: {:error, :cannot_delete_builtin}

  def delete_source(id, user_id) do
    case get_source(id, user_id) do
      {:ok, %Source{} = source} -> Repo.delete(source)
      error -> error
    end
  end

  # --- Documents ---

  def list_documents(source_ref, user_id) do
    Document
    |> where([d], d.source_ref == ^source_ref and d.user_id == ^user_id)
    |> order_by([d], desc: d.updated_at)
    |> Repo.all()
  end

  @default_page_size 20

  def list_documents_paginated(source_ref, user_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    search = Keyword.get(opts, :search, nil)
    parent_id = Keyword.get(opts, :parent_id, :unset)
    offset = (page - 1) * page_size

    base =
      Document
      |> where([d], d.source_ref == ^source_ref and d.user_id == ^user_id)
      |> maybe_search(search)
      |> maybe_filter_parent(parent_id)

    total = base |> select([d], count(d.id)) |> Repo.one()

    documents =
      base
      |> order_by([d], desc: d.updated_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    total_pages = max(ceil(total / page_size), 1)

    %{
      documents: documents,
      page: page,
      page_size: page_size,
      total: total,
      total_pages: total_pages
    }
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    term = "%#{search}%"
    where(query, [d], ilike(d.title, ^term) or ilike(d.content, ^term))
  end

  defp maybe_filter_parent(query, :unset), do: query
  defp maybe_filter_parent(query, nil), do: where(query, [d], is_nil(d.parent_document_id))

  defp maybe_filter_parent(query, parent_id),
    do: where(query, [d], d.parent_document_id == ^parent_id)

  def get_document(id, user_id) do
    case Repo.get(Document, id) do
      nil -> {:error, :not_found}
      %Document{user_id: ^user_id} = doc -> {:ok, doc}
      _ -> {:error, :not_found}
    end
  end

  def get_document_by_slug(source_ref, slug) do
    case Repo.get_by(Document, source_ref: source_ref, slug: slug) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  def create_document(source_ref, attrs, user_id) do
    %Document{}
    |> Document.changeset(
      attrs
      |> Map.put(:source_ref, source_ref)
      |> Map.put(:user_id, user_id)
    )
    |> Repo.insert()
  end

  def update_document(id, attrs, user_id) do
    with {:ok, doc} <- get_document(id, user_id) do
      doc
      |> Document.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_document(id, user_id) do
    with {:ok, doc} <- get_document(id, user_id) do
      Repo.delete(doc)
    end
  end

  def document_count(source_ref) do
    Document
    |> where([d], d.source_ref == ^source_ref)
    |> select([d], count(d.id))
    |> Repo.one()
  end

  # --- Document Tree ---

  def document_tree(source_ref, user_id) do
    documents =
      Document
      |> where([d], d.source_ref == ^source_ref and d.user_id == ^user_id)
      |> order_by([d], asc: d.position)
      |> Repo.all()

    build_document_tree(documents, nil)
  end

  defp build_document_tree(documents, parent_id) do
    documents
    |> Enum.filter(&(&1.parent_document_id == parent_id))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn doc ->
      %{document: doc, children: build_document_tree(documents, doc.id)}
    end)
  end

  def space_tree(source_ref, space_id, user_id) do
    documents =
      Document
      |> where([d], d.source_ref == ^source_ref and d.user_id == ^user_id)
      |> order_by([d], asc: d.position)
      |> Repo.all()

    build_document_tree(documents, space_id)
  end

  def find_root_ancestor(document_id, user_id) do
    case get_document(document_id, user_id) do
      {:ok, %Document{parent_document_id: nil} = doc} -> {:ok, doc}
      {:ok, %Document{parent_document_id: parent_id}} -> find_root_ancestor(parent_id, user_id)
      error -> error
    end
  end

  def create_child_document(source_ref, parent_id, attrs, user_id) do
    next_pos = next_document_position(source_ref, user_id, parent_id)

    %Document{}
    |> Document.changeset(
      attrs
      |> Map.put(:source_ref, source_ref)
      |> Map.put(:user_id, user_id)
      |> Map.put(:parent_document_id, parent_id)
      |> Map.put(:position, next_pos)
    )
    |> Repo.insert()
  end

  defp next_document_position(source_ref, user_id, parent_id) do
    query =
      from(d in Document,
        where: d.source_ref == ^source_ref and d.user_id == ^user_id,
        select: count(d.id)
      )

    query =
      if parent_id do
        where(query, [d], d.parent_document_id == ^parent_id)
      else
        where(query, [d], is_nil(d.parent_document_id))
      end

    Repo.one(query)
  end

  def export_report_to_wiki(report_id, user_id, opts \\ []) do
    alias Liteskill.Reports

    wiki_title = Keyword.get(opts, :title)
    parent_id = Keyword.get(opts, :parent_id)

    with {:ok, report} <- Reports.get_report(report_id, user_id) do
      content = Reports.render_markdown(report, include_comments: false)
      title = wiki_title || report.title

      attrs = %{title: title, content: content}

      result =
        if parent_id do
          create_child_document("builtin:wiki", parent_id, attrs, user_id)
        else
          create_document("builtin:wiki", attrs, user_id)
        end

      case result do
        {:ok, doc} -> {:ok, doc}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end
end

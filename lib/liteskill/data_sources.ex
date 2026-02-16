defmodule Liteskill.DataSources do
  @moduledoc """
  Context for managing data sources and documents.

  Data sources can be either DB-backed (user-created) or built-in
  (defined in code, like Wiki). Documents are always in the DB.
  """

  alias Liteskill.Authorization
  alias Liteskill.DataSources.{Source, Document, SyncWorker}
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

  @doc "Returns the list of configuration fields for a given source type."
  @spec config_fields_for(String.t()) :: [map()]
  def config_fields_for(source_type), do: Map.get(@source_config_fields, source_type, [])

  @available_source_types [
    %{name: "Google Drive", source_type: "google_drive"},
    %{name: "SharePoint", source_type: "sharepoint"},
    %{name: "Confluence", source_type: "confluence"},
    %{name: "Jira", source_type: "jira"},
    %{name: "GitHub", source_type: "github"},
    %{name: "GitLab", source_type: "gitlab"}
  ]

  @doc "Returns the list of available (non-builtin) source type definitions."
  @spec available_source_types() :: [map()]
  def available_source_types, do: @available_source_types

  @doc """
  Validates metadata keys against the allowed config fields for the given source type.

  Returns `{:ok, filtered_map}` with unknown keys stripped, or
  `{:error, :unknown_source_type}` if the source type has no config fields.
  """
  @spec validate_metadata(String.t(), map()) :: {:ok, map()} | {:error, :unknown_source_type}
  def validate_metadata(source_type, metadata) when is_map(metadata) do
    case config_fields_for(source_type) do
      [] ->
        {:error, :unknown_source_type}

      fields ->
        allowed_keys = MapSet.new(fields, & &1.key)
        filtered = Map.filter(metadata, fn {k, _v} -> MapSet.member?(allowed_keys, k) end)
        {:ok, filtered}
    end
  end

  # --- Sources ---

  def list_sources(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("source", user_id)

    db_sources =
      Source
      |> where([s], s.user_id == ^user_id or s.id in subquery(accessible_ids))
      |> order_by([s], asc: s.name)
      |> Repo.all()

    Liteskill.BuiltinSources.virtual_sources() ++ db_sources
  end

  @doc "Like `list_sources/1` but includes `:document_count` on each source."
  @spec list_sources_with_counts(Ecto.UUID.t()) :: [map()]
  def list_sources_with_counts(user_id) do
    list_sources(user_id)
    |> Enum.map(fn source ->
      Map.put(source, :document_count, document_count(source.id))
    end)
  end

  def get_source("builtin:" <> _ = id, _user_id) do
    case Liteskill.BuiltinSources.find(id) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end

  def get_source(id, user_id) do
    case Repo.get(Source, id) do
      nil ->
        {:error, :not_found}

      %Source{user_id: ^user_id} = source ->
        {:ok, source}

      %Source{} = source ->
        if Authorization.has_access?("source", source.id, user_id) do
          {:ok, source}
        else
          {:error, :not_found}
        end
    end
  end

  @doc "Returns the first source owned by the user with the given source_type, or nil."
  @spec get_source_by_type(Ecto.UUID.t(), String.t()) :: Source.t() | nil
  def get_source_by_type(user_id, source_type) do
    Source
    |> where([s], s.user_id == ^user_id and s.source_type == ^source_type)
    |> limit(1)
    |> Repo.one()
  end

  def create_source(attrs, user_id) do
    with :ok <- Liteskill.Rbac.authorize(user_id, "sources:create") do
      Repo.transaction(fn ->
        case %Source{}
             |> Source.changeset(Map.put(attrs, :user_id, user_id))
             |> Repo.insert() do
          {:ok, source} ->
            {:ok, _} = Authorization.create_owner_acl("source", source.id, user_id)
            source

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  def update_source("builtin:" <> _, _attrs, _user_id), do: {:error, :cannot_update_builtin}

  @doc "Updates a user's data source by ID."
  @spec update_source(Ecto.UUID.t(), map(), Ecto.UUID.t()) ::
          {:ok, Source.t()} | {:error, term()}
  def update_source(id, attrs, user_id) do
    with {:ok, source} <- get_source(id, user_id) do
      source
      |> Source.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_source(id, user_id)

  def delete_source("builtin:" <> _, _user_id), do: {:error, :cannot_delete_builtin}

  def delete_source(id, user_id) do
    source =
      case Repo.get(Source, id) do
        %Source{user_id: ^user_id} = s -> s
        _ -> nil
      end

    case source do
      nil ->
        {:error, :not_found}

      %Source{} ->
        Repo.transaction(fn ->
          from(d in Document, where: d.source_ref == ^source.id) |> Repo.delete_all()
          Repo.delete!(source)
        end)
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
      |> where([d], d.source_ref == ^source_ref)
      |> user_or_wiki_acl_filter(source_ref, user_id)
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
    escaped =
      search
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    term = "%#{escaped}%"
    where(query, [d], ilike(d.title, ^term) or ilike(d.content, ^term))
  end

  defp maybe_filter_parent(query, :unset), do: query
  defp maybe_filter_parent(query, nil), do: where(query, [d], is_nil(d.parent_document_id))

  defp maybe_filter_parent(query, parent_id),
    do: where(query, [d], d.parent_document_id == ^parent_id)

  def get_document(id, user_id) do
    case Repo.get(Document, id) do
      nil ->
        {:error, :not_found}

      %Document{user_id: ^user_id} = doc ->
        {:ok, doc}

      %Document{source_ref: "builtin:wiki"} = doc ->
        case get_wiki_space_role(doc.id, user_id) do
          {:ok, _role} -> {:ok, doc}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns `{:ok, doc, role}` where role is "owner" (if user_id matches),
  or the ACL role for wiki spaces, or `:not_found`.
  """
  def get_document_with_role(id, user_id) do
    case Repo.get(Document, id) do
      nil ->
        {:error, :not_found}

      %Document{user_id: ^user_id} = doc ->
        {:ok, doc, "owner"}

      %Document{source_ref: "builtin:wiki"} = doc ->
        case get_wiki_space_role(doc.id, user_id) do
          {:ok, role} -> {:ok, doc, role}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def get_document_by_slug(source_ref, slug) do
    case Repo.get_by(Document, source_ref: source_ref, slug: slug) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  def create_document("builtin:wiki" = source_ref, attrs, user_id) do
    result =
      %Document{}
      |> Document.changeset(
        attrs
        |> Map.put(:source_ref, source_ref)
        |> Map.put(:user_id, user_id)
      )
      |> Repo.insert()

    with {:ok, doc} <- result do
      Authorization.create_owner_acl("wiki_space", doc.id, user_id)

      if doc.content && doc.content != "" do
        enqueue_wiki_sync(doc.id, user_id, "upsert")
      end
    end

    result
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
    case Repo.get(Document, id) do
      nil ->
        {:error, :not_found}

      %Document{user_id: ^user_id} = doc ->
        result = doc |> Document.changeset(attrs) |> Repo.update()

        with {:ok, updated} <- result do
          if doc.source_ref == "builtin:wiki" do
            enqueue_wiki_sync(updated.id, doc.user_id, "upsert")
          end
        end

        result

      %Document{source_ref: "builtin:wiki"} = doc ->
        if can_edit_wiki_doc?(doc.id, user_id) do
          result = doc |> Document.changeset(attrs) |> Repo.update()

          with {:ok, updated} <- result do
            enqueue_wiki_sync(updated.id, doc.user_id, "upsert")
          end

          result
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def delete_document(id, user_id) do
    case Repo.get(Document, id) do
      nil ->
        {:error, :not_found}

      %Document{user_id: ^user_id} = doc ->
        result = Repo.delete(doc)

        with {:ok, deleted} <- result do
          if deleted.source_ref == "builtin:wiki" do
            enqueue_wiki_sync(deleted.id, deleted.user_id, "delete")
          end
        end

        result

      # Deleting a wiki space requires owner
      %Document{source_ref: "builtin:wiki", parent_document_id: nil} = doc ->
        case Authorization.get_role("wiki_space", doc.id, user_id) do
          # coveralls-ignore-start
          {:ok, "owner"} ->
            result = Repo.delete(doc)
            with {:ok, _} <- result, do: enqueue_wiki_sync(doc.id, doc.user_id, "delete")
            result

          # coveralls-ignore-stop
          {:ok, _} ->
            {:error, :forbidden}

          _ ->
            {:error, :not_found}
        end

      # Deleting a wiki child page requires manager+
      %Document{source_ref: "builtin:wiki"} = doc ->
        case find_root_ancestor_by_id(doc.id) do
          {:ok, %Document{id: space_id}} ->
            case Authorization.get_role("wiki_space", space_id, user_id) do
              {:ok, role} when role in ["manager", "owner"] ->
                result = Repo.delete(doc)
                with {:ok, _} <- result, do: enqueue_wiki_sync(doc.id, doc.user_id, "delete")
                result

              {:ok, _} ->
                {:error, :forbidden}

              _ ->
                {:error, :not_found}
            end

          # coveralls-ignore-start
          _ ->
            {:error, :not_found}
            # coveralls-ignore-stop
        end

      _ ->
        {:error, :not_found}
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
    case Repo.get(Document, space_id) do
      nil ->
        []

      %Document{user_id: ^user_id} ->
        Document
        |> where([d], d.source_ref == ^source_ref and d.user_id == ^user_id)
        |> order_by([d], asc: d.position)
        |> Repo.all()
        |> build_document_tree(space_id)

      %Document{source_ref: "builtin:wiki", user_id: space_owner_id} ->
        if Authorization.has_access?("wiki_space", space_id, user_id) do
          Document
          |> where([d], d.source_ref == ^source_ref and d.user_id == ^space_owner_id)
          |> order_by([d], asc: d.position)
          |> Repo.all()
          |> build_document_tree(space_id)
        else
          []
        end

      # coveralls-ignore-start
      _ ->
        []
        # coveralls-ignore-stop
    end
  end

  def find_root_ancestor(document_id, user_id) do
    case find_root_ancestor_by_id(document_id) do
      {:ok, %Document{user_id: ^user_id} = doc} ->
        {:ok, doc}

      {:ok, %Document{source_ref: "builtin:wiki", id: space_id} = doc} ->
        if Authorization.has_access?("wiki_space", space_id, user_id) do
          {:ok, doc}
        else
          {:error, :not_found}
        end

      # coveralls-ignore-start
      {:ok, _doc} ->
        {:error, :not_found}

      # coveralls-ignore-stop

      error ->
        error
    end
  end

  @doc "Returns the root space ID for a wiki document."
  def get_space_id(%Document{parent_document_id: nil, id: id}), do: id

  def get_space_id(%Document{id: id}) do
    case find_root_ancestor_by_id(id) do
      {:ok, root} -> root.id
      # coveralls-ignore-next-line
      _ -> nil
    end
  end

  def create_child_document("builtin:wiki" = source_ref, parent_id, attrs, user_id)
      when not is_nil(parent_id) do
    with {:ok, space} <- find_root_ancestor_by_id(parent_id) do
      if space.user_id == user_id or
           Authorization.can_edit?("wiki_space", space.id, user_id) do
        doc_user_id = space.user_id
        next_pos = next_document_position(source_ref, doc_user_id, parent_id)

        result =
          %Document{}
          |> Document.changeset(
            attrs
            |> Map.put(:source_ref, source_ref)
            |> Map.put(:user_id, doc_user_id)
            |> Map.put(:parent_document_id, parent_id)
            |> Map.put(:position, next_pos)
          )
          |> Repo.insert()

        with {:ok, doc} <- result do
          if doc.content && doc.content != "" do
            enqueue_wiki_sync(doc.id, doc.user_id, "upsert")
          end
        end

        result
      else
        {:error, :forbidden}
      end
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

  # --- Sync Pipeline ---

  def start_sync(source_id, user_id) do
    SyncWorker.new(%{"source_id" => source_id, "user_id" => user_id})
    |> Oban.insert()
  end

  def get_document_by_external_id(source_ref, external_id) do
    case Repo.one(
           from(d in Document,
             where: d.source_ref == ^source_ref and d.external_id == ^external_id
           )
         ) do
      nil ->
        # Fallback: for connectors that use doc.id as external_id (e.g. wiki)
        case Ecto.UUID.cast(external_id) do
          {:ok, uuid} ->
            Repo.one(
              from(d in Document,
                where: d.source_ref == ^source_ref and d.id == ^uuid
              )
            )

          # coveralls-ignore-next-line
          :error ->
            nil
        end

      doc ->
        doc
    end
  end

  def upsert_document_by_external_id(source_ref, external_id, attrs, user_id) do
    case get_document_by_external_id(source_ref, external_id) do
      nil ->
        attrs =
          attrs
          |> Map.put(:external_id, external_id)
          |> Map.put(:content_hash, content_hash(attrs[:content]))

        case create_document(source_ref, attrs, user_id) do
          {:ok, doc} -> {:ok, :created, doc}
          # coveralls-ignore-next-line
          {:error, reason} -> {:error, reason}
        end

      %Document{} = existing ->
        new_hash = content_hash(attrs[:content])

        if existing.content_hash == new_hash do
          {:ok, :unchanged, existing}
        else
          update_attrs =
            attrs
            |> Map.put(:content_hash, new_hash)
            |> Map.put(:external_id, external_id)

          case update_document(existing.id, update_attrs, user_id) do
            {:ok, doc} -> {:ok, :updated, doc}
            # coveralls-ignore-next-line
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  def delete_document_by_external_id(source_ref, external_id, user_id) do
    case get_document_by_external_id(source_ref, external_id) do
      nil -> {:ok, :not_found}
      doc -> delete_document(doc.id, user_id)
    end
  end

  def update_sync_status(source, status, error \\ nil) do
    error = if error, do: String.slice(to_string(error), 0, 10_000)
    attrs = %{sync_status: status, last_sync_error: error}

    attrs =
      if status == "complete" do
        Map.put(attrs, :last_synced_at, DateTime.utc_now() |> DateTime.truncate(:second))
      else
        attrs
      end

    source
    |> Source.sync_changeset(attrs)
    |> Repo.update()
  end

  def update_sync_cursor(source, cursor, document_count) do
    source
    |> Source.sync_changeset(%{sync_cursor: cursor || %{}, sync_document_count: document_count})
    |> Repo.update()
  end

  defp user_or_wiki_acl_filter(query, "builtin:wiki", user_id) do
    accessible_ids = Authorization.accessible_entity_ids("wiki_space", user_id)
    where(query, [d], d.user_id == ^user_id or d.id in subquery(accessible_ids))
  end

  defp user_or_wiki_acl_filter(query, _source_ref, user_id) do
    where(query, [d], d.user_id == ^user_id)
  end

  defp find_root_ancestor_by_id(id, depth \\ 0)
  # coveralls-ignore-next-line
  defp find_root_ancestor_by_id(_, depth) when depth > 100, do: {:error, :too_deep}

  defp find_root_ancestor_by_id(id, depth) do
    case Repo.get(Document, id) do
      nil -> {:error, :not_found}
      %Document{parent_document_id: nil} = doc -> {:ok, doc}
      %Document{parent_document_id: pid} -> find_root_ancestor_by_id(pid, depth + 1)
    end
  end

  defp get_wiki_space_role(document_id, user_id) do
    case find_root_ancestor_by_id(document_id) do
      {:ok, %Document{id: space_id}} -> Authorization.get_role("wiki_space", space_id, user_id)
      # coveralls-ignore-next-line
      _ -> {:error, :no_access}
    end
  end

  def enqueue_wiki_sync(wiki_document_id, user_id, action)
      when action in ["upsert", "delete"] do
    Liteskill.Rag.WikiSyncWorker.new(%{
      "wiki_document_id" => wiki_document_id,
      "user_id" => user_id,
      "action" => action
    })
    |> Oban.insert()
  end

  def enqueue_index_source(source_ref, user_id) do
    count =
      list_documents(source_ref, user_id)
      |> Enum.filter(&(&1.content not in [nil, ""]))
      |> Enum.reduce(0, fn doc, acc ->
        enqueue_wiki_sync(doc.id, user_id, "upsert")
        acc + 1
      end)

    {:ok, count}
  end

  defp can_edit_wiki_doc?(document_id, user_id) do
    case find_root_ancestor_by_id(document_id) do
      {:ok, %Document{id: space_id}} ->
        Authorization.can_edit?("wiki_space", space_id, user_id)

      # coveralls-ignore-start
      _ ->
        false
        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-next-line
  defp content_hash(nil), do: nil
  defp content_hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end

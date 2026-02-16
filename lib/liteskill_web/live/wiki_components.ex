defmodule LiteskillWeb.WikiComponents do
  @moduledoc """
  Function components for the wiki UI.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: LiteskillWeb.Endpoint,
    router: LiteskillWeb.Router,
    statics: LiteskillWeb.static_paths()

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :space, :map, required: true
  attr :space_role, :string, default: nil

  def space_card(assigns) do
    ~H"""
    <div class="relative group">
      <.link navigate={~p"/wiki/#{@space.id}"} class="block">
        <div class="card bg-base-100 border border-base-300 shadow-sm hover:border-primary/50 hover:shadow-md transition-all cursor-pointer h-full">
          <div class="card-body p-4 flex flex-col">
            <div class="flex items-center gap-2">
              <.icon
                name="hero-rectangle-group-micro"
                class="size-4 text-base-content/60 flex-shrink-0"
              />
              <h3 class="font-semibold text-sm truncate">{@space.title}</h3>
              <span
                :if={@space_role && @space_role != "owner"}
                class="badge badge-xs badge-ghost flex-shrink-0"
              >
                Shared
              </span>
            </div>
            <p class="text-xs text-base-content/70 mt-1 line-clamp-3 flex-1 min-h-[3lh]">
              {if @space.content && @space.content != "",
                do: String.slice(@space.content, 0..200),
                else: ""}
            </p>
            <div class="flex items-center mt-2">
              <span class="text-xs text-base-content/50">
                {Calendar.strftime(@space.updated_at, "%b %d, %Y")}
              </span>
            </div>
          </div>
        </div>
      </.link>
      <div
        :if={@space_role in ["manager", "owner"]}
        class="absolute bottom-2 right-2 flex items-center gap-0.5 opacity-0 group-hover:opacity-100 transition-opacity"
      >
        <button
          phx-click="open_sharing"
          phx-value-entity-type="wiki_space"
          phx-value-entity-id={@space.id}
          class="btn btn-ghost btn-xs text-base-content/40 hover:text-primary"
          title="Share space"
        >
          <.icon name="hero-share-micro" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  attr :space, :map, required: true
  attr :space_role, :string, default: nil

  def space_list_item(assigns) do
    ~H"""
    <div class="relative group flex items-center gap-0 rounded-lg border border-base-300 bg-base-100 hover:border-primary/50 hover:bg-base-200/50 transition-all">
      <.link
        navigate={~p"/wiki/#{@space.id}"}
        class="flex items-center gap-3 px-3 py-2.5 flex-1 min-w-0 cursor-pointer"
      >
        <.icon
          name="hero-rectangle-group-micro"
          class="size-4 text-base-content/60 flex-shrink-0"
        />
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2">
            <span class="font-semibold text-sm truncate">{@space.title}</span>
            <span
              :if={@space_role && @space_role != "owner"}
              class="badge badge-xs badge-ghost flex-shrink-0"
            >
              Shared
            </span>
          </div>
          <p
            :if={@space.content && @space.content != ""}
            class="text-xs text-base-content/70 truncate mt-0.5"
          >
            {String.slice(@space.content, 0..120)}
          </p>
        </div>
        <span class="text-xs text-base-content/50 flex-shrink-0">
          {Calendar.strftime(@space.updated_at, "%b %d, %Y")}
        </span>
      </.link>
      <button
        :if={@space_role in ["manager", "owner"]}
        phx-click="open_sharing"
        phx-value-entity-type="wiki_space"
        phx-value-entity-id={@space.id}
        class="btn btn-ghost btn-xs text-base-content/40 hover:text-primary opacity-0 group-hover:opacity-100 transition-opacity flex-shrink-0 mr-2"
        title="Share space"
      >
        <.icon name="hero-share-micro" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :source, :map, required: true
  attr :result, :map, required: true
  attr :search, :string, required: true

  def document_list(assigns) do
    ~H"""
    <div class="space-y-4">
      <form phx-change="source_search" phx-submit="source_search" class="form-control">
        <div class="relative">
          <.icon
            name="hero-magnifying-glass-micro"
            class="size-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
          />
          <input
            type="text"
            name="search"
            value={@search}
            placeholder="Search documents..."
            phx-debounce="300"
            class="input input-bordered input-sm w-full pl-9"
          />
        </div>
      </form>

      <div :if={@result.documents != []} class="space-y-2">
        <.link
          :for={doc <- @result.documents}
          navigate={document_url(@source, doc)}
          class="block card bg-base-100 border border-base-300 shadow-sm hover:border-primary/40 transition-colors cursor-pointer p-3"
        >
          <div class="flex items-start justify-between gap-2">
            <div class="flex-1 min-w-0">
              <h4 class="font-medium text-sm truncate">{doc.title}</h4>
              <p :if={doc.content} class="text-xs text-base-content/60 mt-1 line-clamp-2">
                {String.slice(doc.content || "", 0..200)}
              </p>
            </div>
            <span class="badge badge-ghost badge-xs flex-shrink-0">{doc.content_type}</span>
          </div>
          <div class="flex items-center gap-3 mt-2 text-xs text-base-content/40">
            <span>{Calendar.strftime(doc.updated_at, "%b %d, %Y")}</span>
            <span :if={doc.slug} class="truncate">/{doc.slug}</span>
          </div>
        </.link>
      </div>

      <p
        :if={@result.documents == [] && @search != ""}
        class="text-base-content/50 text-center py-8 text-sm"
      >
        No documents matching "{@search}"
      </p>

      <p
        :if={@result.documents == [] && @search == ""}
        class="text-base-content/50 text-center py-8 text-sm"
      >
        No documents yet.
      </p>

      <div :if={@result.total_pages > 1} class="flex justify-center gap-1 pt-2">
        <button
          :if={@result.page > 1}
          phx-click="source_page"
          phx-value-page={@result.page - 1}
          class="btn btn-ghost btn-xs"
        >
          Previous
        </button>
        <span class="btn btn-ghost btn-xs no-animation">
          {@result.page} / {@result.total_pages}
        </span>
        <button
          :if={@result.page < @result.total_pages}
          phx-click="source_page"
          phx-value-page={@result.page + 1}
          class="btn btn-ghost btn-xs"
        >
          Next
        </button>
      </div>
    </div>
    """
  end

  attr :source, :map, required: true
  attr :document, :map, required: true
  attr :tree, :list, required: true

  def wiki_children(assigns) do
    children = find_children_in_tree(assigns.tree, assigns.document.id)
    assigns = assign(assigns, :children, children)

    ~H"""
    <div :if={@children != []} class="border-t border-base-300 pt-4">
      <h3 class="text-sm font-semibold text-base-content/70 mb-3">Child Pages</h3>
      <div class="space-y-2">
        <.link
          :for={child <- @children}
          navigate={~p"/wiki/#{child.document.id}"}
          class="block card bg-base-100 border border-base-300 shadow-sm hover:border-primary/40 transition-colors cursor-pointer p-3"
        >
          <h4 class="font-medium text-sm">{child.document.title}</h4>
          <p
            :if={child.document.content && child.document.content != ""}
            class="text-xs text-base-content/60 mt-1 line-clamp-2"
          >
            {String.slice(child.document.content, 0..200)}
          </p>
        </.link>
      </div>
    </div>
    """
  end

  attr :tree, :list, required: true
  attr :active_doc_id, :string, default: nil

  def wiki_tree_sidebar(assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={node <- @tree}>
        <.link
          navigate={~p"/wiki/#{node.document.id}"}
          class={[
            "flex items-center gap-1.5 px-2 py-1 rounded text-xs transition-colors truncate",
            if(@active_doc_id == node.document.id,
              do: "bg-primary/10 text-primary font-medium",
              else: "hover:bg-base-200 text-base-content/70"
            )
          ]}
        >
          <.icon name="hero-document-text-micro" class="size-3 flex-shrink-0" />
          <span class="truncate">{node.document.title}</span>
        </.link>
        <div :if={node.children != []} class="ml-3">
          <.wiki_tree_sidebar tree={node.children} active_doc_id={@active_doc_id} />
        </div>
      </li>
    </ul>
    """
  end

  attr :node, :map, required: true
  attr :depth, :integer, required: true
  attr :selected, :string, default: nil

  def wiki_parent_option(assigns) do
    ~H"""
    <option value={@node.document.id} selected={@selected == @node.document.id}>
      {String.duplicate("\u00A0\u00A0", @depth)}
      <%= if @depth > 0 do %>
        └
      <% end %>
      {@node.document.title}
    </option>
    <%= for child <- @node.children do %>
      <.wiki_parent_option node={child} depth={@depth + 1} selected={@selected} />
    <% end %>
    """
  end

  # --- Helpers ---

  defp document_url(source, doc),
    do: ~p"/sources/#{source_url_id(source)}/#{doc.id}"

  def source_url_id(%{id: "builtin:" <> rest}), do: "builtin-" <> rest
  def source_url_id(%{id: id}), do: id

  defp find_children_in_tree([], _id), do: []

  defp find_children_in_tree(tree, id) do
    case Enum.find(tree, fn node -> node.document.id == id end) do
      nil -> Enum.flat_map(tree, fn node -> find_children_in_tree(node.children, id) end)
      node -> node.children
    end
  end
end

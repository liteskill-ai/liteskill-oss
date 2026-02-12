defmodule LiteskillWeb.ReportComponents do
  @moduledoc """
  Function components for the reports UI.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: LiteskillWeb.Endpoint,
    router: LiteskillWeb.Router,
    statics: LiteskillWeb.static_paths()

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :node, :map, required: true
  attr :depth, :integer, required: true
  attr :editing_section_id, :string, default: nil

  def section_node(assigns) do
    tag = heading_tag(assigns.depth)
    editing? = assigns.editing_section_id == assigns.node.section.id
    assigns = assigns |> assign(:tag, tag) |> assign(:editing?, editing?)

    ~H"""
    <div class="mb-4 group/section" id={"section-#{@node.section.id}"}>
      <%= if @editing? do %>
        <div
          id={"editor-#{@node.section.id}"}
          phx-hook="SectionEditor"
          phx-update="ignore"
          data-content={@node.section.content || ""}
          data-section-id={@node.section.id}
          data-title={@node.section.title}
          class="mt-2 border border-base-300 rounded-lg overflow-hidden"
        >
          <div class="px-3 pt-2">
            <input
              type="text"
              data-title-input
              value={@node.section.title}
              class={"input input-bordered input-sm w-full font-semibold #{heading_class(@depth)}"}
              placeholder="Section title"
            />
          </div>
          <div data-editor-target class="min-h-[100px]"></div>
          <div class="flex justify-end gap-2 p-2 border-t border-base-300 bg-base-200/50">
            <button
              type="button"
              phx-click="cancel_edit_section"
              class="btn btn-ghost btn-sm"
            >
              Cancel
            </button>
            <button type="button" data-action="save" class="btn btn-primary btn-sm">
              Save
            </button>
          </div>
        </div>
      <% else %>
        <div class="flex items-center gap-2">
          <span class={"font-semibold #{heading_class(@depth)}"}>{@node.section.title}</span>
          <button
            :if={is_nil(@editing_section_id)}
            phx-click="edit_section"
            phx-value-section-id={@node.section.id}
            class="btn btn-ghost btn-xs opacity-0 group-hover/section:opacity-100 transition-opacity"
            title="Edit section"
          >
            <.icon name="hero-pencil-square-micro" class="size-3.5" />
          </button>
        </div>

        <div
          :if={@node.section.content && @node.section.content != ""}
          class="prose prose-sm max-w-none mt-1 cursor-pointer hover:bg-base-200/30 rounded px-2 py-1 -mx-2 -my-1 transition-colors"
          phx-click="edit_section"
          phx-value-section-id={@node.section.id}
        >
          {LiteskillWeb.Markdown.render(@node.section.content)}
        </div>
      <% end %>

      <div :if={!@editing? && @node.section.comments != []} class="mt-2 space-y-1">
        <.section_comment :for={comment <- @node.section.comments} comment={comment} />
      </div>

      <form :if={!@editing?} phx-submit="add_section_comment" class="mt-2 flex gap-2">
        <input type="hidden" name="section_id" value={@node.section.id} />
        <input
          type="text"
          name="body"
          placeholder="Add a comment..."
          class="input input-bordered input-sm flex-1"
        />
        <button type="submit" class="btn btn-sm btn-ghost">Comment</button>
      </form>

      <div :if={@node.children != []} class="ml-4 mt-2">
        <.section_node
          :for={child <- @node.children}
          node={child}
          depth={@depth + 1}
          editing_section_id={@editing_section_id}
        />
      </div>
    </div>
    """
  end

  attr :comment, :map, required: true

  def section_comment(assigns) do
    replies = if is_list(assigns.comment.replies), do: assigns.comment.replies, else: []
    assigns = assign(assigns, :replies, replies)

    ~H"""
    <div class={[
      "text-sm px-3 py-1.5 rounded",
      if(@comment.status == "addressed",
        do: "bg-success/10 border border-success/20",
        else: "bg-warning/10 border border-warning/20"
      )
    ]}>
      <span class="font-medium">
        {if @comment.author_type == "user", do: "You", else: "Agent"}
      </span>
      <span
        :if={@comment.status == "addressed"}
        class="badge badge-xs badge-success ml-1"
      >
        addressed
      </span>
      <span :if={@comment.status == "open"} class="badge badge-xs badge-warning ml-1">open</span>
      <p class="mt-0.5">{@comment.body}</p>

      <div :if={@replies != []} class="ml-4 mt-1.5 space-y-1">
        <div
          :for={reply <- @replies}
          class="text-xs px-2 py-1 bg-base-200 rounded"
        >
          <span class="font-medium">
            {if reply.author_type == "user", do: "You", else: "Agent"}
          </span>
          <p class="mt-0.5">{reply.body}</p>
        </div>
      </div>

      <form phx-submit="reply_to_comment" class="mt-1.5 flex gap-1">
        <input type="hidden" name="comment_id" value={@comment.id} />
        <input
          type="text"
          name="body"
          placeholder="Reply..."
          class="input input-bordered input-xs flex-1"
        />
        <button type="submit" class="btn btn-xs btn-ghost">Reply</button>
      </form>
    </div>
    """
  end

  attr :report, :map, required: true
  attr :owned, :boolean, required: true

  def report_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/reports/#{@report.id}"}
      class="card bg-base-100 border border-base-300 shadow-sm hover:border-primary/40 transition-colors cursor-pointer"
    >
      <div class="card-body p-4">
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <h3 class="font-semibold text-sm truncate">{@report.title}</h3>
            <p class="text-xs text-base-content/60 mt-0.5">
              {Calendar.strftime(@report.inserted_at, "%b %d, %Y")}
            </p>
          </div>
          <span :if={!@owned} class="badge badge-sm badge-info">shared</span>
        </div>
        <div class="card-actions justify-end mt-2">
          <button
            :if={@owned}
            phx-click="delete_report"
            phx-value-id={@report.id}
            data-confirm="Delete this report and all its sections?"
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash-micro" class="size-4" /> Delete
          </button>
          <button
            :if={!@owned}
            phx-click="leave_report"
            phx-value-id={@report.id}
            data-confirm="Leave this shared report?"
            class="btn btn-ghost btn-xs text-warning"
          >
            <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" /> Leave
          </button>
        </div>
      </div>
    </.link>
    """
  end

  # --- Helpers ---

  defp heading_tag(1), do: "h1"
  defp heading_tag(2), do: "h2"
  defp heading_tag(3), do: "h3"
  defp heading_tag(_), do: "h4"

  defp heading_class(1), do: "text-xl"
  defp heading_class(2), do: "text-lg"
  defp heading_class(3), do: "text-base"
  defp heading_class(_), do: "text-sm"
end

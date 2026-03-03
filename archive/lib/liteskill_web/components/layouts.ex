defmodule LiteskillWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use LiteskillWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo_dark_mode.svg"} width="36" class="hidden dark:block" />
          <img src={~p"/images/logo_light_mode.svg"} width="36" class="block dark:hidden" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  attr :sidebar_open, :boolean, required: true
  attr :live_action, :atom, required: true
  attr :conversations, :list, required: true
  attr :active_conversation_id, :any, default: nil
  attr :current_user, :map, required: true
  attr :has_admin_access, :boolean, required: true
  attr :single_user_mode, :boolean, default: false

  def sidebar(assigns) do
    ~H"""
    <aside
      id="sidebar"
      phx-hook="SidebarNav"
      class={[
        "flex-shrink-0 bg-base-200 flex flex-col border-r border-base-300 transition-all duration-200 overflow-hidden",
        if(@sidebar_open,
          do: "w-64 max-sm:fixed max-sm:inset-0 max-sm:w-full max-sm:z-40",
          else: "w-0 border-r-0"
        )
      ]}
    >
      <div class="flex items-center justify-between p-3 border-b border-base-300 min-w-64">
        <div class="flex items-center gap-2">
          <img src={~p"/images/logo_dark_mode.svg"} class="size-7 hidden dark:block" />
          <img src={~p"/images/logo_light_mode.svg"} class="size-7 block dark:hidden" />
          <span class="text-lg tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
            LiteSkill
          </span>
        </div>
        <div class="flex items-center gap-1">
          <.theme_toggle />
          <button phx-click="toggle_sidebar" class="btn btn-circle btn-ghost btn-sm">
            <.icon name="hero-arrow-left-end-on-rectangle-micro" class="size-5" />
          </button>
        </div>
      </div>

      <div class="flex items-center justify-between px-3 py-2 min-w-64">
        <.link
          navigate={~p"/conversations"}
          class={[
            "text-sm font-semibold tracking-wide hover:text-primary transition-colors",
            if(@live_action == :conversations,
              do: "text-primary",
              else: "text-base-content/70"
            )
          ]}
        >
          Conversations
        </.link>
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm btn-circle" title="New Chat">
          <.icon name="hero-plus-micro" class="size-4" />
        </.link>
      </div>

      <nav class="flex-1 overflow-y-auto px-2 space-y-1 pb-4 min-w-64">
        <LiteskillWeb.ChatComponents.conversation_item
          :for={conv <- @conversations}
          conversation={conv}
          active={@active_conversation_id == conv.id}
        />
        <p
          :if={@conversations == []}
          class="text-xs text-base-content/50 text-center py-4"
        >
          No conversations yet
        </p>
      </nav>

      <div class="p-2 border-t border-base-300 min-w-64">
        <.link
          navigate={~p"/wiki"}
          class={[
            "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
            if(@live_action in [:wiki, :wiki_page_show],
              do: "bg-primary/10 text-primary font-medium",
              else: "hover:bg-base-200 text-base-content/70"
            )
          ]}
        >
          <.icon name="hero-book-open-micro" class="size-4" /> Wiki
        </.link>
        <.link
          navigate={~p"/sources"}
          class={[
            "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
            if(@live_action in [:sources, :source_show, :source_document_show],
              do: "bg-primary/10 text-primary font-medium",
              else: "hover:bg-base-200 text-base-content/70"
            )
          ]}
        >
          <.icon name="hero-circle-stack-micro" class="size-4" /> Data Sources
        </.link>
        <.link
          navigate={~p"/mcp"}
          class={[
            "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
            if(@live_action == :mcp_servers,
              do: "bg-primary/10 text-primary font-medium",
              else: "hover:bg-base-200 text-base-content/70"
            )
          ]}
        >
          <.icon name="hero-wrench-screwdriver-micro" class="size-4" /> Tools
        </.link>
        <.link
          navigate={~p"/reports"}
          class={[
            "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
            if(@live_action in [:reports, :report_show],
              do: "bg-primary/10 text-primary font-medium",
              else: "hover:bg-base-200 text-base-content/70"
            )
          ]}
        >
          <.icon name="hero-document-text-micro" class="size-4" /> Reports
        </.link>
      </div>
      <div class="p-2 border-t border-base-300 min-w-64">
        <.link
          navigate={~p"/agents"}
          class={[
            "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
            if(LiteskillWeb.AgentStudioLive.studio_action?(@live_action),
              do: "bg-primary/10 text-primary font-medium",
              else: "hover:bg-base-200 text-base-content/70"
            )
          ]}
        >
          <.icon name="hero-cpu-chip-micro" class="size-4" /> Agent Studio
        </.link>
      </div>

      <div
        :if={@has_admin_access or @single_user_mode}
        class="p-2 border-t border-base-300 min-w-64"
      >
        <.link
          navigate={if @single_user_mode, do: ~p"/settings", else: ~p"/admin"}
          class={[
            "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
            if(
              LiteskillWeb.AdminLive.admin_action?(@live_action) or
                LiteskillWeb.SettingsLive.settings_action?(@live_action),
              do: "bg-primary/10 text-primary font-medium",
              else: "hover:bg-base-200 text-base-content/70"
            )
          ]}
        >
          <.icon name="hero-cog-6-tooth-micro" class="size-4" /> {if @single_user_mode,
            do: "Settings",
            else: "Admin"}
        </.link>
      </div>

      <div :if={!@single_user_mode} class="p-3 border-t border-base-300 min-w-64">
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/profile"}
            class={[
              "flex-1 truncate text-sm hover:text-base-content",
              if(LiteskillWeb.ProfileLive.profile_action?(@live_action),
                do: "text-primary font-medium",
                else: "text-base-content/70"
              )
            ]}
          >
            {@current_user.email}
          </.link>
          <.link href={~p"/auth/logout"} method="delete" class="btn btn-ghost btn-xs">
            <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" />
          </.link>
        </div>
      </div>
    </aside>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="dropdown dropdown-bottom dropdown-end">
      <div tabindex="0" role="button" class="btn btn-circle btn-ghost btn-sm">
        <.icon
          name="hero-sun-micro"
          class="size-5 hidden [[data-theme=light]_&]:block"
        />
        <.icon
          name="hero-moon-micro"
          class="size-5 hidden [[data-theme=dark]_&]:block"
        />
        <.icon
          name="hero-computer-desktop-micro"
          class="size-5 [[data-theme=light]_&]:hidden [[data-theme=dark]_&]:hidden"
        />
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-200 rounded-box z-10 w-36 p-2 shadow-lg mt-2"
      >
        <li>
          <button phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="dark">
            <.icon name="hero-moon-micro" class="size-4" /> Dark
          </button>
        </li>
        <li>
          <button phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="light">
            <.icon name="hero-sun-micro" class="size-4" /> Light
          </button>
        </li>
        <li>
          <button phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="system">
            <.icon name="hero-computer-desktop-micro" class="size-4" /> System
          </button>
        </li>
      </ul>
    </div>
    """
  end
end

defmodule LiteskillWeb.SetupLive do
  use LiteskillWeb, :live_view

  alias Liteskill.Accounts
  alias Liteskill.DataSources

  @data_sources DataSources.available_source_types()

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Initial Setup",
       step: :password,
       form: to_form(%{"password" => "", "password_confirmation" => ""}, as: :setup),
       error: nil,
       data_sources: @data_sources,
       selected_sources: MapSet.new(),
       sources_to_configure: [],
       current_config_index: 0,
       config_form: to_form(%{}, as: :config)
     ), layout: {LiteskillWeb.Layouts, :root}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200 px-4">
      <%= cond do %>
        <% @step == :password -> %>
          <.password_step form={@form} error={@error} />
        <% @step == :data_sources -> %>
          <.data_sources_step
            data_sources={@data_sources}
            selected_sources={@selected_sources}
          />
        <% @step == :configure_source -> %>
          <.configure_source_step
            source={Enum.at(@sources_to_configure, @current_config_index)}
            config_fields={config_fields_for(Enum.at(@sources_to_configure, @current_config_index))}
            config_form={@config_form}
            current_index={@current_config_index}
            total={length(@sources_to_configure)}
          />
      <% end %>
    </div>
    """
  end

  defp config_fields_for(source) do
    DataSources.config_fields_for(source.source_type)
  end

  attr :form, :any, required: true
  attr :error, :string

  defp password_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl w-full max-w-md">
      <div class="card-body">
        <h2 class="card-title text-2xl">Welcome to Liteskill</h2>
        <p class="text-base-content/70">
          Set a password for the admin account to get started.
        </p>

        <.form for={@form} phx-submit="setup" class="mt-4 space-y-4">
          <div class="form-control">
            <label class="label"><span class="label-text">Password</span></label>
            <input
              type="password"
              name="setup[password]"
              value={Phoenix.HTML.Form.input_value(@form, :password)}
              placeholder="Minimum 12 characters"
              class="input input-bordered w-full"
              required
              minlength="12"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Confirm Password</span></label>
            <input
              type="password"
              name="setup[password_confirmation]"
              value={Phoenix.HTML.Form.input_value(@form, :password_confirmation)}
              placeholder="Repeat password"
              class="input input-bordered w-full"
              required
              minlength="12"
            />
          </div>

          <p :if={@error} class="text-error text-sm">{@error}</p>

          <button type="submit" class="btn btn-primary w-full">Set Password & Continue</button>
        </.form>
      </div>
    </div>
    """
  end

  attr :data_sources, :list, required: true
  attr :selected_sources, :any, required: true

  defp data_sources_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl w-full max-w-2xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">Connect Your Data Sources</h2>
        <p class="text-base-content/70">
          Select the data sources you'd like to integrate with. You can always change this later.
        </p>

        <div class="grid grid-cols-2 sm:grid-cols-3 gap-4 mt-6">
          <button
            :for={source <- @data_sources}
            type="button"
            phx-click="toggle_source"
            phx-value-key={source.key}
            class={[
              "flex flex-col items-center justify-center gap-3 p-6 rounded-xl border-2 transition-all duration-200 cursor-pointer",
              if(MapSet.member?(@selected_sources, source.key),
                do: "bg-success/15 border-success shadow-md",
                else: "bg-base-100 border-base-300 hover:border-base-content/30"
              ),
              "hover:scale-105"
            ]}
          >
            <div class={[
              "size-12 flex items-center justify-center",
              if(MapSet.member?(@selected_sources, source.key),
                do: "text-success",
                else: "text-base-content/70"
              )
            ]}>
              <.source_icon key={source.key} />
            </div>
            <span class={[
              "text-sm font-medium",
              if(MapSet.member?(@selected_sources, source.key),
                do: "text-success",
                else: "text-base-content"
              )
            ]}>
              {source.name}
            </span>
          </button>
        </div>

        <div class="flex gap-3 mt-8">
          <button phx-click="skip_sources" class="btn btn-ghost flex-1">
            Skip for now
          </button>
          <button phx-click="save_sources" class="btn btn-primary flex-1">
            Continue
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :source, :map, required: true
  attr :config_fields, :list, required: true
  attr :config_form, :any, required: true
  attr :current_index, :integer, required: true
  attr :total, :integer, required: true

  defp configure_source_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl w-full max-w-lg">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h2 class="card-title text-2xl">Configure {@source.name}</h2>
          <span class="text-sm text-base-content/50">
            {@current_index + 1} of {@total}
          </span>
        </div>
        <p class="text-base-content/70">
          Enter connection details for {@source.name}. You can skip this and configure later.
        </p>

        <div class="flex justify-center my-4">
          <div class="size-16">
            <.source_icon key={@source.key} />
          </div>
        </div>

        <.form for={@config_form} phx-submit="save_config" class="space-y-4">
          <div :for={field <- @config_fields} class="form-control">
            <label class="label"><span class="label-text">{field.label}</span></label>
            <%= if field.type == :textarea do %>
              <textarea
                name={"config[#{field.key}]"}
                placeholder={field.placeholder}
                class="textarea textarea-bordered w-full"
                rows="4"
              />
            <% else %>
              <input
                type={if field.type == :password, do: "password", else: "text"}
                name={"config[#{field.key}]"}
                placeholder={field.placeholder}
                class="input input-bordered w-full"
              />
            <% end %>
          </div>

          <div class="flex gap-3 mt-6">
            <button type="button" phx-click="skip_config" class="btn btn-ghost flex-1">
              Skip
            </button>
            <button type="submit" class="btn btn-primary flex-1">
              Save & Continue
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :key, :string, required: true

  defp source_icon(%{key: "google_drive"} = assigns) do
    ~H"""
    <svg viewBox="0 0 87.3 78" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <path
        d="m6.6 66.85 3.85 6.65c.8 1.4 1.95 2.5 3.3 3.3l13.75-23.8h-27.5c0 1.55.4 3.1 1.2 4.5z"
        fill="#0066da"
      />
      <path
        d="m43.65 25-13.75-23.8c-1.35.8-2.5 1.9-3.3 3.3l-20.4 35.3c-.8 1.4-1.2 2.95-1.2 4.5h27.5z"
        fill="#00ac47"
      />
      <path
        d="m73.55 76.8c1.35-.8 2.5-1.9 3.3-3.3l1.6-2.75 7.65-13.25c.8-1.4 1.2-2.95 1.2-4.5h-27.5l5.85 13.55z"
        fill="#ea4335"
      />
      <path
        d="m43.65 25 13.75-23.8c-1.35-.8-2.9-1.2-4.5-1.2h-18.5c-1.6 0-3.15.45-4.5 1.2z"
        fill="#00832d"
      />
      <path
        d="m59.8 53h-32.3l-13.75 23.8c1.35.8 2.9 1.2 4.5 1.2h50.8c1.6 0 3.15-.45 4.5-1.2z"
        fill="#2684fc"
      />
      <path
        d="m73.4 26.5-10.1-17.5c-.8-1.4-1.95-2.5-3.3-3.3l-13.75 23.8 16.15 23.5h27.45c0-1.55-.4-3.1-1.2-4.5z"
        fill="#ffba00"
      />
    </svg>
    """
  end

  defp source_icon(%{key: "sharepoint"} = assigns) do
    ~H"""
    <svg viewBox="0 0 48 48" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <circle cx="24" cy="18" r="14" fill="#036c70" />
      <circle cx="17" cy="30" r="12" fill="#1a9ba1" />
      <circle cx="24" cy="38" r="10" fill="#37c6d0" />
      <path
        d="M28 8v32c0 1.1-.9 2-2 2H12V10c0-1.1.9-2 2-2h14z"
        fill="white"
        fill-opacity="0.2"
      />
    </svg>
    """
  end

  defp source_icon(%{key: "confluence"} = assigns) do
    ~H"""
    <svg viewBox="0 0 256 246" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="conf-a" x1="99.14%" y1="34.32%" x2="34.32%" y2="76.39%">
          <stop stop-color="#0052CC" offset="18%" />
          <stop stop-color="#2684FF" offset="100%" />
        </linearGradient>
        <linearGradient id="conf-b" x1="0.86%" y1="65.68%" x2="65.68%" y2="23.61%">
          <stop stop-color="#0052CC" offset="18%" />
          <stop stop-color="#2684FF" offset="100%" />
        </linearGradient>
      </defs>
      <path
        d="M9.26 187.48c-3.7 6.27-7.85 13.6-10.86 19.08a9.27 9.27 0 0 0 3.63 12.75l57.45 30.17a9.34 9.34 0 0 0 12.56-3.09c2.56-4.18 5.8-9.75 9.46-16 24.77-42.2 49.7-37.15 99.57-14.45l56.35 25.6a9.28 9.28 0 0 0 12.37-4.72l26.3-57.77a9.23 9.23 0 0 0-4.47-12.25c-15.2-6.87-45.3-20.47-75.1-34C105.88 93.92 47.65 119.2 9.26 187.48z"
        fill="url(#conf-a)"
      />
      <path
        d="M246.74 58.52c3.7-6.27 7.85-13.6 10.86-19.08a9.27 9.27 0 0 0-3.63-12.75L196.52-3.48a9.34 9.34 0 0 0-12.56 3.09c-2.56 4.18-5.8 9.75-9.46 16-24.77 42.2-49.7 37.15-99.57 14.45L18.58 4.47A9.28 9.28 0 0 0 6.21 9.19l-26.3 57.77a9.23 9.23 0 0 0 4.47 12.25c15.2 6.87 45.3 20.47 75.1 34 90.68 39.88 148.91 14.6 187.26-54.69z"
        fill="url(#conf-b)"
      />
    </svg>
    """
  end

  defp source_icon(%{key: "jira"} = assigns) do
    ~H"""
    <svg viewBox="0 0 256 256" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="jira-a" x1="98.03%" y1="0.22%" x2="58.89%" y2="40.77%">
          <stop stop-color="#0052CC" offset="18%" />
          <stop stop-color="#2684FF" offset="100%" />
        </linearGradient>
        <linearGradient id="jira-b" x1="100.17%" y1="-.52%" x2="55.42%" y2="44.13%">
          <stop stop-color="#0052CC" offset="18%" />
          <stop stop-color="#2684FF" offset="100%" />
        </linearGradient>
      </defs>
      <path
        d="M244.66 0H121.72a55.34 55.34 0 0 0 55.34 55.34h22.14v21.4a55.34 55.34 0 0 0 55.34 55.34V10.88A10.88 10.88 0 0 0 244.66 0z"
        fill="#2684FF"
      />
      <path
        d="M183.83 61.25H60.89a55.34 55.34 0 0 0 55.34 55.34h22.14v21.4a55.34 55.34 0 0 0 55.34 55.34V72.13a10.88 10.88 0 0 0-9.88-10.88z"
        fill="url(#jira-a)"
      />
      <path
        d="M122.95 122.5H0a55.34 55.34 0 0 0 55.34 55.34h22.14v21.4a55.34 55.34 0 0 0 55.34 55.34V133.38a10.88 10.88 0 0 0-9.87-10.88z"
        fill="url(#jira-b)"
      />
    </svg>
    """
  end

  defp source_icon(%{key: "github"} = assigns) do
    ~H"""
    <svg viewBox="0 0 98 96" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M48.854 0C21.839 0 0 22 0 49.217c0 21.756 13.993 40.172 33.405 46.69 2.427.49 3.316-1.059 3.316-2.362 0-1.141-.08-5.052-.08-9.127-13.59 2.934-16.42-5.867-16.42-5.867-2.184-5.704-5.42-7.17-5.42-7.17-4.448-3.015.324-3.015.324-3.015 4.934.326 7.523 5.052 7.523 5.052 4.367 7.496 11.404 5.378 14.235 4.074.404-3.178 1.699-5.378 3.074-6.6-10.839-1.141-22.243-5.378-22.243-24.283 0-5.378 1.94-9.778 5.014-13.2-.485-1.222-2.184-6.275.486-13.038 0 0 4.125-1.304 13.426 5.052a46.97 46.97 0 0 1 12.214-1.63c4.125 0 8.33.571 12.213 1.63 9.302-6.356 13.427-5.052 13.427-5.052 2.67 6.763.97 11.816.485 13.038 3.155 3.422 5.015 7.822 5.015 13.2 0 18.905-11.404 23.06-22.324 24.283 1.78 1.548 3.316 4.481 3.316 9.126 0 6.6-.08 11.897-.08 13.526 0 1.304.89 2.853 3.316 2.364 19.412-6.52 33.405-24.935 33.405-46.691C97.707 22 75.788 0 48.854 0z"
        fill="currentColor"
      />
    </svg>
    """
  end

  defp source_icon(%{key: "gitlab"} = assigns) do
    ~H"""
    <svg viewBox="0 0 380 380" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <path d="m190.41 345.09-68.24-210.07h136.48z" fill="#e24329" />
      <path d="m190.41 345.09-68.24-210.07H18.72z" fill="#fc6d26" />
      <path
        d="M18.72 135.02 3.33 182.35a10.47 10.47 0 0 0 3.81 11.71l183.27 133.03z"
        fill="#fca326"
      />
      <path
        d="M18.72 135.02h103.45L76.05 9.37c-2.39-7.36-12.84-7.36-15.23 0z"
        fill="#e24329"
      />
      <path d="m190.41 345.09 68.24-210.07h103.45z" fill="#fc6d26" />
      <path
        d="M362.1 135.02 377.49 182.35a10.47 10.47 0 0 1-3.81 11.71L190.41 345.09z"
        fill="#fca326"
      />
      <path
        d="M362.1 135.02H258.65l46.12-125.65c2.39-7.36 12.84-7.36 15.23 0z"
        fill="#e24329"
      />
    </svg>
    """
  end

  @impl true
  def handle_event("setup", %{"setup" => params}, socket) do
    password = params["password"]
    confirmation = params["password_confirmation"]

    cond do
      password != confirmation ->
        {:noreply, assign(socket, error: "Passwords do not match")}

      String.length(password) < 12 ->
        {:noreply, assign(socket, error: "Password must be at least 12 characters")}

      true ->
        case Accounts.setup_admin_password(socket.assigns.current_user, password) do
          {:ok, user} ->
            {:noreply,
             socket
             |> assign(step: :data_sources, current_user: user, error: nil)}

          {:error, _changeset} ->
            {:noreply, assign(socket, error: "Failed to set password. Please try again.")}
        end
    end
  end

  @impl true
  def handle_event("toggle_source", %{"key" => key}, socket) do
    selected = socket.assigns.selected_sources

    selected =
      if MapSet.member?(selected, key) do
        MapSet.delete(selected, key)
      else
        MapSet.put(selected, key)
      end

    {:noreply, assign(socket, selected_sources: selected)}
  end

  @impl true
  def handle_event("save_sources", _params, socket) do
    user_id = socket.assigns.current_user.id
    selected = socket.assigns.selected_sources

    sources_to_configure =
      @data_sources
      |> Enum.filter(fn source -> MapSet.member?(selected, source.key) end)

    if sources_to_configure == [] do
      {:noreply, redirect(socket, to: "/login")}
    else
      created_sources =
        Enum.map(sources_to_configure, fn source ->
          {:ok, db_source} =
            DataSources.create_source(
              %{name: source.name, source_type: source.source_type, description: ""},
              user_id
            )

          Map.put(source, :db_id, db_source.id)
        end)

      {:noreply,
       socket
       |> assign(
         step: :configure_source,
         sources_to_configure: created_sources,
         current_config_index: 0,
         config_form: to_form(%{}, as: :config)
       )}
    end
  end

  @impl true
  def handle_event("save_config", %{"config" => config_params}, socket) do
    current_source =
      Enum.at(socket.assigns.sources_to_configure, socket.assigns.current_config_index)

    user_id = socket.assigns.current_user.id

    metadata =
      config_params
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    if metadata != %{} do
      DataSources.update_source(current_source.db_id, %{metadata: metadata}, user_id)
    end

    advance_config(socket)
  end

  @impl true
  def handle_event("skip_config", _params, socket) do
    advance_config(socket)
  end

  @impl true
  def handle_event("skip_sources", _params, socket) do
    {:noreply, redirect(socket, to: "/login")}
  end

  defp advance_config(socket) do
    next_index = socket.assigns.current_config_index + 1

    if next_index >= length(socket.assigns.sources_to_configure) do
      {:noreply, redirect(socket, to: "/login")}
    else
      {:noreply,
       socket
       |> assign(
         current_config_index: next_index,
         config_form: to_form(%{}, as: :config)
       )}
    end
  end
end

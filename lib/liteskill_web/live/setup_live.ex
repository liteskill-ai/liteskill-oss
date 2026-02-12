defmodule LiteskillWeb.SetupLive do
  use LiteskillWeb, :live_view

  alias Liteskill.Accounts
  alias Liteskill.DataSources
  alias LiteskillWeb.SourcesComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Initial Setup",
       step: :password,
       form: to_form(%{"password" => "", "password_confirmation" => ""}, as: :setup),
       error: nil,
       data_sources: DataSources.available_source_types(),
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
            phx-value-source-type={source.source_type}
            class={[
              "flex flex-col items-center justify-center gap-3 p-6 rounded-xl border-2 transition-all duration-200 cursor-pointer",
              if(MapSet.member?(@selected_sources, source.source_type),
                do: "bg-success/15 border-success shadow-md",
                else: "bg-base-100 border-base-300 hover:border-base-content/30"
              ),
              "hover:scale-105"
            ]}
          >
            <div class={[
              "size-12 flex items-center justify-center",
              if(MapSet.member?(@selected_sources, source.source_type),
                do: "text-success",
                else: "text-base-content/70"
              )
            ]}>
              <SourcesComponents.source_type_icon source_type={source.source_type} />
            </div>
            <span class={[
              "text-sm font-medium",
              if(MapSet.member?(@selected_sources, source.source_type),
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
            <SourcesComponents.source_type_icon source_type={@source.source_type} />
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
  def handle_event("toggle_source", %{"source-type" => source_type}, socket) do
    selected = socket.assigns.selected_sources

    selected =
      if MapSet.member?(selected, source_type) do
        MapSet.delete(selected, source_type)
      else
        MapSet.put(selected, source_type)
      end

    {:noreply, assign(socket, selected_sources: selected)}
  end

  @impl true
  def handle_event("save_sources", _params, socket) do
    user_id = socket.assigns.current_user.id
    selected = socket.assigns.selected_sources
    data_sources = socket.assigns.data_sources

    sources_to_configure =
      Enum.filter(data_sources, fn source -> MapSet.member?(selected, source.source_type) end)

    if sources_to_configure == [] do
      {:noreply, redirect(socket, to: "/login")}
    else
      {created_sources, error} =
        Enum.reduce_while(sources_to_configure, {[], nil}, fn source, {acc, _} ->
          case DataSources.create_source(
                 %{name: source.name, source_type: source.source_type, description: ""},
                 user_id
               ) do
            {:ok, db_source} ->
              {:cont, {[Map.put(source, :db_id, db_source.id) | acc], nil}}

            {:error, _} ->
              {:halt, {acc, "Failed to create source: #{source.name}"}}
          end
        end)

      if error do
        {:noreply, assign(socket, error: error)}
      else
        {:noreply,
         socket
         |> assign(
           step: :configure_source,
           sources_to_configure: Enum.reverse(created_sources),
           current_config_index: 0,
           config_form: to_form(%{}, as: :config)
         )}
      end
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
      case DataSources.update_source(current_source.db_id, %{metadata: metadata}, user_id) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
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

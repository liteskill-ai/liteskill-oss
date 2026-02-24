defmodule LiteskillWeb.AdminLive.SetupTab do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2, redirect: 2, push_event: 3]

  import LiteskillWeb.AdminLive.Helpers,
    only: [require_admin: 2, build_provider_attrs: 2, build_model_attrs: 2]

  alias Liteskill.DataSources
  alias Liteskill.LlmModels
  alias Liteskill.LlmProviders
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.OpenRouter
  alias Liteskill.Settings
  alias LiteskillWeb.OpenRouterController
  alias LiteskillWeb.SourcesComponents

  def assigns do
    [
      setup_steps: [:password, :default_permissions, :providers, :models, :rag, :data_sources],
      setup_step: :password,
      setup_form: to_form(%{"password" => "", "password_confirmation" => ""}, as: :setup),
      setup_error: nil,
      setup_selected_permissions: MapSet.new(),
      setup_data_sources: [],
      setup_selected_sources: MapSet.new(),
      setup_sources_to_configure: [],
      setup_current_config_index: 0,
      setup_config_form: to_form(%{}, as: :config),
      setup_llm_providers: [],
      setup_llm_models: [],
      setup_llm_provider_form: to_form(%{}, as: :llm_provider),
      setup_llm_model_form: to_form(%{}, as: :llm_model),
      setup_rag_embedding_models: [],
      setup_rag_current_model: nil,
      setup_provider_view: :presets,
      setup_openrouter_pending: false,
      or_models: nil,
      or_search: "",
      or_results: [],
      or_loading: false,
      embed_results_all: [],
      embed_search: "",
      embed_results: []
    ]
  end

  def load_data(socket) do
    user_id = socket.assigns.current_user.id
    single_user = Liteskill.SingleUser.enabled?()
    available = DataSources.available_source_types()

    existing_types =
      available
      |> Enum.map(& &1.source_type)
      |> Enum.filter(&DataSources.get_source_by_type(user_id, &1))
      |> MapSet.new()

    default_perms =
      case Liteskill.Rbac.get_role_by_name!("Default") do
        %{permissions: perms} -> MapSet.new(perms)
      end

    settings = Settings.get()

    steps =
      if single_user do
        [:providers, :models, :rag, :data_sources]
      else
        [:password, :default_permissions, :providers, :models, :rag, :data_sources]
      end

    assign(socket,
      page_title: "Setup Wizard",
      setup_steps: steps,
      setup_step: hd(steps),
      setup_form: to_form(%{"password" => "", "password_confirmation" => ""}, as: :setup),
      setup_error: nil,
      setup_selected_permissions: default_perms,
      setup_data_sources: available,
      setup_selected_sources: existing_types,
      setup_sources_to_configure: [],
      setup_current_config_index: 0,
      setup_config_form: to_form(%{}, as: :config),
      setup_llm_providers: LlmProviders.list_all_providers(),
      setup_llm_models: LlmModels.list_all_models(),
      setup_llm_provider_form: to_form(%{}, as: :llm_provider),
      setup_llm_model_form: to_form(%{}, as: :llm_model),
      setup_rag_embedding_models: LlmModels.list_all_active_models(model_type: "embedding"),
      setup_rag_current_model: settings.embedding_model,
      setup_provider_view: :presets,
      setup_openrouter_pending: false,
      or_models: nil,
      or_search: "",
      or_results: [],
      or_loading: false,
      embed_search: ""
    )
    |> load_embed_models()
  end

  # --- Password ---

  def handle_event("setup_password", %{"setup" => params}, socket) do
    require_admin(socket, fn ->
      password = params["password"]
      confirmation = params["password_confirmation"]

      cond do
        password != confirmation ->
          {:noreply, assign(socket, setup_error: "Passwords do not match")}

        String.length(password) < 12 ->
          {:noreply,
           assign(socket,
             setup_error: "Password must be at least 12 characters"
           )}

        true ->
          case Liteskill.Accounts.setup_admin_password(socket.assigns.current_user, password) do
            {:ok, user} ->
              {:noreply,
               assign(socket,
                 setup_step: :default_permissions,
                 current_user: user,
                 setup_error: nil
               )}

            {:error, reason} ->
              {:noreply,
               assign(socket,
                 setup_error: action_error("set password", reason)
               )}
          end
      end
    end)
  end

  def handle_event("setup_skip_password", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_step: :default_permissions, setup_error: nil)}
    end)
  end

  # --- Permissions ---

  def handle_event("setup_toggle_permission", %{"permission" => permission}, socket) do
    require_admin(socket, fn ->
      selected = socket.assigns.setup_selected_permissions

      selected =
        if MapSet.member?(selected, permission),
          do: MapSet.delete(selected, permission),
          else: MapSet.put(selected, permission)

      {:noreply, assign(socket, setup_selected_permissions: selected)}
    end)
  end

  def handle_event("setup_save_permissions", _params, socket) do
    require_admin(socket, fn ->
      permissions = MapSet.to_list(socket.assigns.setup_selected_permissions)
      role = Liteskill.Rbac.get_role_by_name!("Default")

      case Liteskill.Rbac.update_role(role, %{permissions: permissions}) do
        {:ok, _} ->
          {:noreply, assign(socket, setup_step: :providers, setup_error: nil)}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             setup_error: action_error("update permissions", reason)
           )}
      end
    end)
  end

  def handle_event("setup_skip_permissions", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_step: :providers, setup_error: nil)}
    end)
  end

  # --- OpenRouter OAuth ---

  def handle_event("setup_openrouter_connect", _params, socket) do
    require_admin(socket, fn ->
      if Liteskill.SingleUser.enabled?() do
        user = socket.assigns.current_user
        {verifier, challenge} = OpenRouter.generate_pkce()
        callback_url = LiteskillWeb.Endpoint.url() <> ~p"/auth/openrouter/callback"

        state = OpenRouter.StateStore.store(verifier, user.id, "/admin/setup")
        auth_url = OpenRouter.auth_url(callback_url <> "?state=#{state}", challenge)

        Phoenix.PubSub.subscribe(
          Liteskill.PubSub,
          OpenRouterController.openrouter_topic(user.id)
        )

        {:noreply,
         socket
         |> assign(setup_openrouter_pending: true)
         |> push_event("open_external_url", %{url: auth_url})}
      else
        {:noreply, redirect(socket, to: ~p"/auth/openrouter?return_to=/admin/setup")}
      end
    end)
  end

  # --- Providers ---

  def handle_event("setup_providers_show_custom", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_provider_view: :custom)}
    end)
  end

  def handle_event("setup_providers_show_presets", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_provider_view: :presets)}
    end)
  end

  def handle_event("setup_create_provider", %{"llm_provider" => params}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id

      case build_provider_attrs(params, user_id) do
        {:ok, attrs} ->
          case LlmProviders.create_provider(attrs) do
            {:ok, _provider} ->
              providers = LlmProviders.list_all_providers()

              {:noreply,
               assign(socket,
                 setup_llm_providers: providers,
                 setup_llm_provider_form: to_form(%{}, as: :llm_provider),
                 setup_error: nil
               )}

            {:error, changeset} ->
              {:noreply,
               assign(socket,
                 setup_error: action_error("create provider", changeset)
               )}
          end

        {:error, msg} ->
          {:noreply, assign(socket, setup_error: msg)}
      end
    end)
  end

  def handle_event("setup_providers_continue", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_step: :models, setup_error: nil)}
    end)
  end

  def handle_event("setup_providers_skip", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_step: :models, setup_error: nil)}
    end)
  end

  # --- OpenRouter Model Search ---

  def handle_event("or_search", %{"or_query" => query}, socket) do
    require_admin(socket, fn ->
      socket =
        if is_nil(socket.assigns.or_models) do
          case Liteskill.OpenRouter.Models.list_models() do
            {:ok, models} ->
              assign(socket, or_models: models, or_loading: false)

            {:error, _} ->
              assign(socket, or_models: [], or_loading: false)
          end
        else
          socket
        end

      results =
        if String.trim(query) == "" do
          []
        else
          Liteskill.OpenRouter.Models.search_models(socket.assigns.or_models, query)
        end

      {:noreply, assign(socket, or_search: query, or_results: results)}
    end)
  end

  def handle_event("or_select_model", %{"model-id" => model_id}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id

      or_provider =
        Enum.find(socket.assigns.setup_llm_providers, &(&1.provider_type == "openrouter"))

      case Enum.find(socket.assigns.or_models || [], &(&1.id == model_id)) do
        nil ->
          {:noreply, assign(socket, setup_error: "Model not found")}

        model ->
          attrs = %{
            name: model.name,
            model_id: model.id,
            provider_id: or_provider.id,
            model_type: model.model_type,
            input_cost_per_million: model.input_cost_per_million,
            output_cost_per_million: model.output_cost_per_million,
            instance_wide: true,
            status: "active",
            user_id: user_id
          }

          case LlmModels.create_model(attrs) do
            {:ok, _} ->
              models = LlmModels.list_all_models()
              embedding_models = LlmModels.list_all_active_models(model_type: "embedding")

              {:noreply,
               assign(socket,
                 setup_llm_models: models,
                 setup_rag_embedding_models: embedding_models,
                 or_search: "",
                 or_results: [],
                 setup_error: nil
               )}

            {:error, changeset} ->
              {:noreply,
               assign(socket,
                 setup_error: action_error("add model", changeset)
               )}
          end
      end
    end)
  end

  # --- Embedding Catalog ---

  def handle_event("embed_search", %{"embed_query" => query}, socket) do
    require_admin(socket, fn ->
      embed_models = socket.assigns.embed_results_all

      results =
        if String.trim(query) == "" do
          embed_models
        else
          Liteskill.EmbeddingCatalog.search_models(embed_models, query)
        end

      {:noreply, assign(socket, embed_search: query, embed_results: results)}
    end)
  end

  def handle_event("embed_select_model", %{"model-id" => model_id}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id
      providers = socket.assigns.setup_llm_providers

      case Enum.find(socket.assigns.embed_results_all, &(&1.id == model_id)) do
        nil ->
          {:noreply, assign(socket, setup_error: "Model not found")}

        model ->
          case Liteskill.EmbeddingCatalog.resolve_provider(model, providers) do
            :error ->
              {:noreply,
               assign(socket,
                 setup_error: "No compatible provider configured for this model"
               )}

            {:ok, provider_id} ->
              attrs = %{
                name: model.name,
                model_id: model.id,
                provider_id: provider_id,
                model_type: "embedding",
                input_cost_per_million: model.input_cost_per_million,
                output_cost_per_million: model.output_cost_per_million,
                instance_wide: true,
                status: "active",
                user_id: user_id
              }

              case LlmModels.create_model(attrs) do
                {:ok, _} ->
                  models = LlmModels.list_all_models()
                  embedding_models = LlmModels.list_all_active_models(model_type: "embedding")

                  {:noreply,
                   assign(socket,
                     setup_llm_models: models,
                     setup_rag_embedding_models: embedding_models,
                     embed_search: "",
                     embed_results: socket.assigns.embed_results_all,
                     setup_error: nil
                   )}

                {:error, changeset} ->
                  {:noreply,
                   assign(socket,
                     setup_error: action_error("add embedding model", changeset)
                   )}
              end
          end
      end
    end)
  end

  # --- Models ---

  def handle_event("setup_create_model", %{"llm_model" => params}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id

      params =
        if socket.assigns.single_user_mode do
          Map.merge(params, %{"instance_wide" => "true", "status" => "active"})
        else
          params
        end

      case build_model_attrs(params, user_id) do
        {:ok, attrs} ->
          case LlmModels.create_model(attrs) do
            {:ok, _model} ->
              models = LlmModels.list_all_models()
              embedding_models = LlmModels.list_all_active_models(model_type: "embedding")

              {:noreply,
               assign(socket,
                 setup_llm_models: models,
                 setup_rag_embedding_models: embedding_models,
                 setup_llm_model_form: to_form(%{}, as: :llm_model),
                 setup_error: nil
               )}

            {:error, changeset} ->
              {:noreply,
               assign(socket,
                 setup_error: action_error("create model", changeset)
               )}
          end

        {:error, msg} ->
          {:noreply, assign(socket, setup_error: msg)}
      end
    end)
  end

  def handle_event("setup_models_continue", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_step: :rag, setup_error: nil)}
    end)
  end

  def handle_event("setup_models_skip", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_step: :rag, setup_error: nil)}
    end)
  end

  # --- RAG ---

  def handle_event("setup_select_embedding", %{"model_id" => model_id}, socket) do
    require_admin(socket, fn ->
      model_id = if model_id == "", do: nil, else: model_id

      case Settings.update_embedding_model(model_id) do
        {:ok, settings} ->
          {:noreply,
           assign(socket,
             setup_rag_current_model: settings.embedding_model,
             setup_step: :data_sources,
             setup_error: nil
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             setup_error: action_error("update embedding model", reason)
           )}
      end
    end)
  end

  def handle_event("setup_rag_skip", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, assign(socket, setup_step: :data_sources, setup_error: nil)}
    end)
  end

  # --- Data Sources ---

  def handle_event("setup_toggle_source", %{"source-type" => source_type}, socket) do
    require_admin(socket, fn ->
      selected = socket.assigns.setup_selected_sources

      selected =
        if MapSet.member?(selected, source_type),
          do: MapSet.delete(selected, source_type),
          else: MapSet.put(selected, source_type)

      {:noreply, assign(socket, setup_selected_sources: selected)}
    end)
  end

  def handle_event("setup_save_sources", _params, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id
      selected = socket.assigns.setup_selected_sources
      data_sources = socket.assigns.setup_data_sources

      sources_to_configure =
        Enum.filter(data_sources, &MapSet.member?(selected, &1.source_type))

      if sources_to_configure == [] do
        {:noreply, push_navigate(socket, to: ~p"/admin/servers")}
      else
        {configured, _error} =
          Enum.reduce(sources_to_configure, {[], nil}, fn source, {acc, err} ->
            if err do
              {acc, err}
            else
              ensure_source_exists(source, user_id, acc)
            end
          end)

        sources = Enum.reverse(configured)
        first = hd(sources)

        existing_metadata =
          case DataSources.get_source(first.db_id, user_id) do
            {:ok, s} -> s.metadata || %{}
            _ -> %{}
          end

        steps = socket.assigns.setup_steps
        steps = if :configure_source in steps, do: steps, else: steps ++ [:configure_source]

        {:noreply,
         assign(socket,
           setup_step: :configure_source,
           setup_steps: steps,
           setup_sources_to_configure: sources,
           setup_current_config_index: 0,
           setup_config_form: to_form(existing_metadata, as: :config)
         )}
      end
    end)
  end

  def handle_event("setup_save_config", %{"config" => config_params}, socket) do
    require_admin(socket, fn ->
      current_source =
        Enum.at(
          socket.assigns.setup_sources_to_configure,
          socket.assigns.setup_current_config_index
        )

      user_id = socket.assigns.current_user.id

      metadata =
        config_params
        |> Enum.reject(fn {_k, v} -> v == "" end)
        |> Map.new()

      if metadata != %{} do
        DataSources.update_source(current_source.db_id, %{metadata: metadata}, user_id)
      end

      setup_advance_config(socket)
    end)
  end

  def handle_event("setup_skip_config", _params, socket) do
    require_admin(socket, fn ->
      setup_advance_config(socket)
    end)
  end

  def handle_event("setup_skip_sources", _params, socket) do
    require_admin(socket, fn ->
      {:noreply, push_navigate(socket, to: ~p"/admin/servers")}
    end)
  end

  # --- Private Helpers ---

  defp setup_advance_config(socket) do
    next_index = socket.assigns.setup_current_config_index + 1
    sources = socket.assigns.setup_sources_to_configure

    if next_index >= length(sources) do
      {:noreply, push_navigate(socket, to: ~p"/admin/servers")}
    else
      user_id = socket.assigns.current_user.id
      next_source = Enum.at(sources, next_index)

      existing_metadata =
        case DataSources.get_source(next_source.db_id, user_id) do
          {:ok, s} -> s.metadata || %{}
          _ -> %{}
        end

      {:noreply,
       assign(socket,
         setup_current_config_index: next_index,
         setup_config_form: to_form(existing_metadata, as: :config)
       )}
    end
  end

  defp load_embed_models(socket) do
    providers = socket.assigns.setup_llm_providers
    models = fetch_embed_models(providers)
    assign(socket, embed_results_all: models, embed_results: models)
  end

  defp fetch_embed_models(providers) do
    provider_types = Enum.map(providers, & &1.provider_type)

    Liteskill.EmbeddingCatalog.fetch_models()
    |> Liteskill.EmbeddingCatalog.filter_for_providers(provider_types)
  end

  defp ensure_source_exists(source, user_id, acc) do
    case DataSources.get_source_by_type(user_id, source.source_type) do
      %{id: id} ->
        {[Map.put(source, :db_id, id) | acc], nil}

      nil ->
        case DataSources.create_source(
               %{name: source.name, source_type: source.source_type, description: ""},
               user_id
             ) do
          {:ok, db_source} ->
            {[Map.put(source, :db_id, db_source.id) | acc], nil}

          {:error, reason} ->
            {acc, action_error("create source #{source.name}", reason)}
        end
    end
  end

  # --- Render ---

  def render_tab(assigns) do
    ~H"""
    <div class="flex justify-center">
      <div class="w-full max-w-2xl">
        <div class="mb-4">
          <.link navigate={~p"/admin/servers"} class="btn btn-ghost btn-sm gap-1">
            <.icon name="hero-arrow-left-micro" class="size-4" /> Back to Server
          </.link>
        </div>

        <div class="flex gap-2 mb-6">
          <.setup_step_indicator
            :for={{s, idx} <- Enum.with_index(@setup_steps, 1)}
            label={setup_step_label(s)}
            step={s}
            current={@setup_step}
            index={idx}
            total={length(@setup_steps)}
            steps={@setup_steps}
          />
        </div>

        <%= case @setup_step do %>
          <% :password -> %>
            <.setup_password_step form={@setup_form} error={@setup_error} />
          <% :default_permissions -> %>
            <.setup_default_permissions_step selected_permissions={@setup_selected_permissions} />
          <% :providers -> %>
            <.setup_providers_step
              llm_providers={@setup_llm_providers}
              llm_provider_form={@setup_llm_provider_form}
              provider_view={@setup_provider_view}
              openrouter_pending={@setup_openrouter_pending}
              error={@setup_error}
            />
          <% :models -> %>
            <.setup_models_step
              llm_models={@setup_llm_models}
              llm_providers={@setup_llm_providers}
              llm_model_form={@setup_llm_model_form}
              single_user={@single_user_mode}
              or_search={@or_search}
              or_results={@or_results}
              or_loading={@or_loading}
              embed_search={@embed_search}
              embed_results={@embed_results}
              error={@setup_error}
            />
          <% :rag -> %>
            <.setup_rag_step
              rag_embedding_models={@setup_rag_embedding_models}
              rag_current_model={@setup_rag_current_model}
              error={@setup_error}
            />
          <% :data_sources -> %>
            <.setup_data_sources_step
              data_sources={@setup_data_sources}
              selected_sources={@setup_selected_sources}
            />
          <% :configure_source -> %>
            <.setup_configure_step
              source={Enum.at(@setup_sources_to_configure, @setup_current_config_index)}
              config_form={@setup_config_form}
              current_index={@setup_current_config_index}
              total={length(@setup_sources_to_configure)}
            />
        <% end %>
      </div>
    </div>
    """
  end

  # --- Setup Sub-Components ---

  defp setup_step_indicator(assigns) do
    current_idx = Enum.find_index(assigns.steps, &(&1 == assigns.current)) || 0
    step_idx = Enum.find_index(assigns.steps, &(&1 == assigns.step)) || 0

    status =
      cond do
        assigns.step == assigns.current -> :active
        step_idx < current_idx -> :done
        true -> :pending
      end

    assigns = assign(assigns, :status, status)

    ~H"""
    <div class="flex items-center gap-2 flex-1">
      <div class={[
        "size-6 rounded-full flex items-center justify-center text-xs font-bold",
        case @status do
          :done -> "bg-success text-success-content"
          :active -> "bg-primary text-primary-content"
          :pending -> "bg-base-300 text-base-content/50"
        end
      ]}>
        <%= if @status == :done do %>
          <.icon name="hero-check-micro" class="size-4" />
        <% else %>
          {@index}
        <% end %>
      </div>
      <span class={[
        "text-sm font-medium",
        if(@status == :pending, do: "text-base-content/50", else: "text-base-content")
      ]}>
        {@label}
      </span>
      <div :if={@index < @total} class="flex-1 h-px bg-base-300" />
    </div>
    """
  end

  defp setup_step_label(:password), do: "Password"
  defp setup_step_label(:default_permissions), do: "Permissions"
  defp setup_step_label(:providers), do: "Providers"
  defp setup_step_label(:models), do: "Models"
  defp setup_step_label(:rag), do: "RAG"
  defp setup_step_label(:data_sources), do: "Data Sources"
  defp setup_step_label(:configure_source), do: "Configure"

  defp setup_password_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">Admin Password</h2>
        <p class="text-base-content/70">
          Set or update the admin account password. Skip if no change is needed.
        </p>

        <.form for={@form} phx-submit="setup_password" class="mt-4 space-y-4">
          <div class="form-control">
            <label class="label"><span class="label-text">New Password</span></label>
            <input
              type="password"
              name="setup[password]"
              value={Phoenix.HTML.Form.input_value(@form, :password)}
              placeholder="Minimum 12 characters"
              class="input input-bordered w-full"
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
              minlength="12"
            />
          </div>

          <p :if={@error} class="text-error text-sm">{@error}</p>

          <div class="flex gap-3">
            <button type="button" phx-click="setup_skip_password" class="btn btn-ghost flex-1">
              Skip
            </button>
            <button type="submit" class="btn btn-primary flex-1">
              Set Password & Continue
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp setup_default_permissions_step(assigns) do
    grouped = Liteskill.Rbac.Permissions.grouped()
    assigns = assign(assigns, :grouped_permissions, grouped)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">Default User Permissions</h2>
        <p class="text-base-content/70">
          Choose the baseline permissions that all users receive by default.
        </p>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
          <%= for {category, perms} <- @grouped_permissions do %>
            <div class="border border-base-300 rounded-lg p-3">
              <h4 class="font-semibold text-sm mb-2 capitalize">{category}</h4>
              <%= for perm <- perms do %>
                <label class="flex items-center gap-2 py-0.5 cursor-pointer">
                  <input
                    type="checkbox"
                    phx-click="setup_toggle_permission"
                    phx-value-permission={perm}
                    checked={MapSet.member?(@selected_permissions, perm)}
                    class="checkbox checkbox-sm"
                  />
                  <span class="text-xs">{perm}</span>
                </label>
              <% end %>
            </div>
          <% end %>
        </div>

        <div class="flex gap-3 mt-6">
          <button type="button" phx-click="setup_skip_permissions" class="btn btn-ghost flex-1">
            Skip
          </button>
          <button type="button" phx-click="setup_save_permissions" class="btn btn-primary flex-1">
            Save & Continue
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp setup_providers_step(%{provider_view: :presets} = assigns) do
    ~H"""
    <div id="admin-providers-presets" phx-hook="OpenExternalUrl" class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">LLM Providers</h2>
        <p class="text-base-content/70">
          Add at least one LLM provider to enable AI chat.
        </p>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 mt-6">
          <button
            type="button"
            phx-click="setup_providers_show_custom"
            class="flex flex-col items-center gap-3 p-6 rounded-xl border-2 border-base-300 hover:border-base-content/30 hover:bg-base-200 cursor-pointer transition-all"
          >
            <span class="text-2xl font-bold">Manual Entry</span>
            <span class="text-sm text-base-content/60">Any OpenAI-compatible provider</span>
            <span class="badge badge-ghost badge-sm">API Key</span>
          </button>

          <button
            type="button"
            phx-click="setup_openrouter_connect"
            disabled={@openrouter_pending}
            class={[
              "flex flex-col items-center gap-3 p-6 rounded-xl border-2 transition-all",
              if(@openrouter_pending,
                do: "border-primary/30 bg-primary/5 opacity-70 cursor-wait",
                else:
                  "border-primary/30 bg-primary/5 hover:border-primary hover:bg-primary/10 cursor-pointer"
              )
            ]}
          >
            <span class="text-2xl font-bold">OpenRouter</span>
            <span class="text-sm text-base-content/60">Access 200+ models</span>
            <%= if @openrouter_pending do %>
              <span class="badge badge-primary badge-sm gap-1">
                <span class="loading loading-spinner loading-xs"></span> Waiting for authorization...
              </span>
            <% else %>
              <span class="badge badge-primary badge-sm">Connect</span>
            <% end %>
          </button>
        </div>

        <div :if={@llm_providers != []} class="mt-4">
          <h4 class="font-semibold text-sm mb-2">Configured Providers</h4>
          <div class="space-y-1">
            <div
              :for={p <- @llm_providers}
              class="flex items-center justify-between p-2 bg-base-200 rounded"
            >
              <div class="flex items-center gap-2">
                <span class="badge badge-success badge-xs" />
                <span class="text-sm font-medium">{p.name}</span>
                <span class="text-xs text-base-content/50">{p.provider_type}</span>
              </div>
            </div>
          </div>
        </div>

        <div class="flex gap-3 mt-6">
          <button type="button" phx-click="setup_providers_skip" class="btn btn-ghost flex-1">
            Skip
          </button>
          <button
            type="button"
            phx-click="setup_providers_continue"
            class="btn btn-primary flex-1"
          >
            Continue
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp setup_providers_step(%{provider_view: :custom} = assigns) do
    provider_types = LlmProvider.valid_provider_types()
    assigns = assign(assigns, :provider_types, provider_types)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center gap-2 mb-2">
          <button
            type="button"
            phx-click="setup_providers_show_presets"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" /> Back
          </button>
          <h2 class="card-title text-xl">Add Custom Provider</h2>
        </div>
        <p class="text-base-content/70">
          Configure any provider supported by ReqLLM (AWS Bedrock, Anthropic, Google, etc).
        </p>

        <div class="mt-4 p-4 border border-base-300 rounded-lg">
          <.form for={@llm_provider_form} phx-submit="setup_create_provider" class="space-y-3">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Name</span></label>
                <input
                  type="text"
                  name="llm_provider[name]"
                  class="input input-bordered input-sm w-full"
                  required
                  placeholder="AWS Bedrock US-East"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Provider Type</span></label>
                <select
                  name="llm_provider[provider_type]"
                  class="select select-bordered select-sm w-full"
                >
                  <%= for pt <- @provider_types do %>
                    <option value={pt}>{pt}</option>
                  <% end %>
                </select>
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">API Key</span></label>
                <input
                  type="password"
                  name="llm_provider[api_key]"
                  class="input input-bordered input-sm w-full"
                  placeholder="Optional — encrypted at rest"
                />
              </div>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Provider Config (JSON)</span>
              </label>
              <textarea
                name="llm_provider[provider_config_json]"
                class="textarea textarea-bordered textarea-sm w-full font-mono"
                rows="2"
                placeholder='{"region": "us-east-1"}'
              />
            </div>
            <label class="label cursor-pointer gap-2 w-fit">
              <input
                type="checkbox"
                name="llm_provider[instance_wide]"
                value="true"
                checked
                class="checkbox checkbox-sm"
              />
              <span class="label-text">Instance-wide (all users)</span>
            </label>
            <p :if={@error} class="text-error text-sm">{@error}</p>
            <button type="submit" class="btn btn-primary btn-sm">Add Provider</button>
          </.form>
        </div>

        <div :if={@llm_providers != []} class="mt-4">
          <h4 class="font-semibold text-sm mb-2">Configured Providers</h4>
          <div class="space-y-1">
            <div
              :for={p <- @llm_providers}
              class="flex items-center justify-between p-2 bg-base-200 rounded"
            >
              <div class="flex items-center gap-2">
                <span class="badge badge-success badge-xs" />
                <span class="text-sm font-medium">{p.name}</span>
                <span class="text-xs text-base-content/50">{p.provider_type}</span>
              </div>
            </div>
          </div>
        </div>

        <div class="flex gap-3 mt-6">
          <button type="button" phx-click="setup_providers_skip" class="btn btn-ghost flex-1">
            Skip
          </button>
          <button type="button" phx-click="setup_providers_continue" class="btn btn-primary flex-1">
            Continue
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp setup_models_step(assigns) do
    model_types = LlmModels.LlmModel.valid_model_types()

    or_provider =
      Enum.find(assigns.llm_providers, &(&1.provider_type == "openrouter"))

    assigns =
      assigns
      |> assign(:model_types, model_types)
      |> assign(:or_provider, or_provider)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">LLM Models</h2>
        <p class="text-base-content/70">
          Add models that users can chat with. You'll need at least one inference model,
          and an embedding model if you want RAG.
        </p>

        <%= if @llm_providers == [] do %>
          <div class="alert alert-warning mt-4">
            <.icon name="hero-exclamation-triangle-micro" class="size-5" />
            <span>No providers configured. Go back and add a provider first, or skip for now.</span>
          </div>
        <% else %>
          <div :if={@or_provider} class="mt-4 p-4 border border-primary/20 bg-primary/5 rounded-lg">
            <h3 class="font-semibold mb-3">Browse OpenRouter Inference Models</h3>
            <form phx-change="or_search" class="relative">
              <input
                type="text"
                name="or_query"
                value={@or_search}
                placeholder="Search models (e.g. claude, gpt, llama)..."
                class="input input-bordered input-sm w-full"
                phx-debounce="300"
                autocomplete="off"
              />
              <span :if={@or_loading} class="absolute right-3 top-2">
                <span class="loading loading-spinner loading-xs"></span>
              </span>
            </form>
            <div
              :if={@or_results != []}
              class="mt-2 max-h-64 overflow-y-auto border border-base-300 rounded-lg divide-y divide-base-300"
            >
              <button
                :for={m <- @or_results}
                type="button"
                phx-click="or_select_model"
                phx-value-model-id={m.id}
                class="flex items-center justify-between w-full px-3 py-2 text-left hover:bg-base-200 transition-colors cursor-pointer"
              >
                <div>
                  <div class="text-sm font-medium">{m.name}</div>
                  <div class="text-xs text-base-content/50 font-mono">{m.id}</div>
                </div>
                <div class="text-right text-xs text-base-content/50 shrink-0 ml-2">
                  <div :if={m.context_length}>
                    {div(m.context_length, 1000)}K ctx
                  </div>
                  <div :if={m.input_cost_per_million}>
                    ${Decimal.round(m.input_cost_per_million, 2)}/M in
                  </div>
                </div>
              </button>
            </div>
            <p
              :if={@or_search != "" && @or_results == [] && !@or_loading}
              class="text-sm text-base-content/50 mt-2"
            >
              No models found matching "{@or_search}"
            </p>
          </div>

          <div
            :if={@embed_results != [] || @embed_search != ""}
            class="mt-4 p-4 border border-secondary/20 bg-secondary/5 rounded-lg"
          >
            <h3 class="font-semibold mb-3">Browse Embedding Models</h3>
            <p class="text-xs text-base-content/50 mb-2">
              Embedding models from OpenRouter compatible with your configured providers.
            </p>
            <form phx-change="embed_search" class="relative">
              <input
                type="text"
                name="embed_query"
                value={@embed_search}
                placeholder="Filter embedding models..."
                class="input input-bordered input-sm w-full"
                phx-debounce="100"
                autocomplete="off"
              />
            </form>
            <div
              :if={@embed_results != []}
              class="mt-2 max-h-64 overflow-y-auto border border-base-300 rounded-lg divide-y divide-base-300"
            >
              <button
                :for={m <- @embed_results}
                type="button"
                phx-click="embed_select_model"
                phx-value-model-id={m.id}
                class="flex items-center justify-between w-full px-3 py-2 text-left hover:bg-base-200 transition-colors cursor-pointer"
              >
                <div>
                  <div class="text-sm font-medium">{m.name}</div>
                  <div class="text-xs text-base-content/50 font-mono">{m.id}</div>
                </div>
                <div class="text-right text-xs text-base-content/50 shrink-0 ml-2">
                  <div :if={m[:dimensions]}>{m.dimensions}d</div>
                  <div :if={m[:context_length] && !m[:dimensions]}>{m.context_length} ctx</div>
                  <div :if={m.input_cost_per_million}>
                    ${Decimal.round(m.input_cost_per_million, 2)}/M in
                  </div>
                </div>
              </button>
            </div>
            <p
              :if={@embed_search != "" && @embed_results == []}
              class="text-sm text-base-content/50 mt-2"
            >
              No embedding models found matching "{@embed_search}"
            </p>
          </div>

          <div class="mt-4 p-4 border border-base-300 rounded-lg">
            <h3 class="font-semibold mb-3">Add Model Manually</h3>
            <.form for={@llm_model_form} phx-submit="setup_create_model" class="space-y-3">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div class="form-control">
                  <label class="label"><span class="label-text">Display Name</span></label>
                  <input
                    type="text"
                    name="llm_model[name]"
                    class="input input-bordered input-sm w-full"
                    required
                    placeholder="Claude Sonnet"
                  />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">Provider</span></label>
                  <select
                    name="llm_model[provider_id]"
                    class="select select-bordered select-sm w-full"
                    required
                  >
                    <%= for p <- @llm_providers do %>
                      <option value={p.id}>{p.name}</option>
                    <% end %>
                  </select>
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">Model ID</span></label>
                  <input
                    type="text"
                    name="llm_model[model_id]"
                    class="input input-bordered input-sm w-full"
                    required
                    placeholder="us.anthropic.claude-sonnet-4-20250514"
                  />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">Model Type</span></label>
                  <select
                    name="llm_model[model_type]"
                    class="select select-bordered select-sm w-full"
                  >
                    <%= for mt <- @model_types do %>
                      <option value={mt}>{mt}</option>
                    <% end %>
                  </select>
                </div>
              </div>
              <label :if={!@single_user} class="label cursor-pointer gap-2 w-fit">
                <input
                  type="checkbox"
                  name="llm_model[instance_wide]"
                  value="true"
                  checked
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">Instance-wide (all users)</span>
              </label>
              <p :if={@error} class="text-error text-sm">{@error}</p>
              <button type="submit" class="btn btn-primary btn-sm">Add Model</button>
            </.form>
          </div>
        <% end %>

        <div :if={@llm_models != []} class="mt-4">
          <h4 class="font-semibold text-sm mb-2">Configured Models</h4>
          <div class="space-y-1">
            <div
              :for={m <- @llm_models}
              class="flex items-center justify-between p-2 bg-base-200 rounded"
            >
              <div class="flex items-center gap-2">
                <span class="badge badge-success badge-xs" />
                <span class="text-sm font-medium">{m.name}</span>
                <span class="text-xs text-base-content/50">{m.model_id}</span>
                <span class="badge badge-ghost badge-xs">{m.model_type}</span>
              </div>
            </div>
          </div>
        </div>

        <div class="flex gap-3 mt-6">
          <button type="button" phx-click="setup_models_skip" class="btn btn-ghost flex-1">
            Skip
          </button>
          <button type="button" phx-click="setup_models_continue" class="btn btn-primary flex-1">
            Continue
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp setup_rag_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">RAG Embedding Model</h2>
        <p class="text-base-content/70">
          Select an embedding model to enable Retrieval-Augmented Generation (RAG).
        </p>

        <%= if @rag_current_model do %>
          <div class="flex items-center gap-2 mt-4">
            <span class="badge badge-success">Active</span>
            <span class="font-medium">{@rag_current_model.name}</span>
            <span class="text-sm text-base-content/60">({@rag_current_model.model_id})</span>
          </div>
        <% end %>

        <%= if @rag_embedding_models == [] do %>
          <div class="alert alert-info mt-4">
            <.icon name="hero-information-circle-micro" class="size-5" />
            <span>
              No embedding models available. Add a model with type "embedding" first,
              or skip for now.
            </span>
          </div>
        <% else %>
          <form phx-submit="setup_select_embedding" class="mt-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Select Embedding Model</span></label>
              <select name="model_id" class="select select-bordered w-full">
                <option value="">-- None (disable RAG) --</option>
                <option
                  :for={model <- @rag_embedding_models}
                  value={model.id}
                  selected={@rag_current_model && model.id == @rag_current_model.id}
                >
                  {model.name} ({model.model_id})
                </option>
              </select>
            </div>
            <p :if={@error} class="text-error text-sm mt-2">{@error}</p>
            <button type="submit" class="btn btn-primary mt-4">
              Save & Continue
            </button>
          </form>
        <% end %>

        <div class="flex gap-3 mt-6">
          <button type="button" phx-click="setup_rag_skip" class="btn btn-ghost flex-1">
            Skip for now
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp setup_data_sources_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-xl">Data Sources</h2>
        <p class="text-base-content/70">
          Select the data sources to integrate with. Already-connected sources are pre-selected.
        </p>

        <div class="grid grid-cols-2 sm:grid-cols-3 gap-4 mt-6">
          <%= for source <- @data_sources do %>
            <% coming_soon = source.source_type in ~w(sharepoint confluence jira github gitlab) %>
            <button
              type="button"
              phx-click={unless(coming_soon, do: "setup_toggle_source")}
              phx-value-source-type={source.source_type}
              disabled={coming_soon}
              class={[
                "flex flex-col items-center justify-center gap-3 p-6 rounded-xl border-2 transition-all duration-200",
                cond do
                  coming_soon ->
                    "border-base-300 opacity-50 cursor-not-allowed"

                  MapSet.member?(@selected_sources, source.source_type) ->
                    "bg-success/15 border-success shadow-md"

                  true ->
                    "bg-base-100 border-base-300 hover:border-base-content/30 cursor-pointer hover:scale-105"
                end
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
              <span :if={coming_soon} class="badge badge-xs badge-ghost">Coming Soon</span>
            </button>
          <% end %>
        </div>

        <div class="flex gap-3 mt-8">
          <button phx-click="setup_skip_sources" class="btn btn-ghost flex-1">
            Skip
          </button>
          <button phx-click="setup_save_sources" class="btn btn-primary flex-1">
            Continue
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp setup_configure_step(assigns) do
    config_fields = DataSources.config_fields_for(assigns.source.source_type)
    assigns = assign(assigns, :config_fields, config_fields)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <h2 class="card-title text-xl">Configure {@source.name}</h2>
          <span class="text-sm text-base-content/50">
            {@current_index + 1} of {@total}
          </span>
        </div>
        <p class="text-base-content/70">
          Enter connection details for {@source.name}. Skip to keep existing config.
        </p>

        <div class="flex justify-center my-4">
          <div class="size-16">
            <SourcesComponents.source_type_icon source_type={@source.source_type} />
          </div>
        </div>

        <.form for={@config_form} phx-submit="setup_save_config" class="space-y-4">
          <div :for={field <- @config_fields} class="form-control">
            <label class="label"><span class="label-text">{field.label}</span></label>
            <%= if field.type == :textarea do %>
              <textarea
                name={"config[#{field.key}]"}
                placeholder={field.placeholder}
                class="textarea textarea-bordered w-full"
                rows="4"
              >{Phoenix.HTML.Form.input_value(@config_form, field.key)}</textarea>
            <% else %>
              <input
                type={if field.type == :password, do: "password", else: "text"}
                name={"config[#{field.key}]"}
                value={Phoenix.HTML.Form.input_value(@config_form, field.key)}
                placeholder={field.placeholder}
                class="input input-bordered w-full"
              />
            <% end %>
          </div>

          <div class="flex gap-3 mt-6">
            <button type="button" phx-click="setup_skip_config" class="btn btn-ghost flex-1">
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
end

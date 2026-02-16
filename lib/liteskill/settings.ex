defmodule Liteskill.Settings do
  @moduledoc """
  The Settings context. Manages server-wide settings using a singleton row pattern.

  Uses :persistent_term for caching since settings rarely change.
  """

  alias Liteskill.Repo
  alias Liteskill.Settings.ServerSettings

  import Ecto.Query

  @cache_key {__MODULE__, :settings}
  @cache_enabled Application.compile_env(:liteskill, :settings_cache, true)

  def get do
    if @cache_enabled do
      # coveralls-ignore-start
      case :persistent_term.get(@cache_key, nil) do
        nil -> load_and_cache()
        settings -> settings
      end

      # coveralls-ignore-stop
    else
      load_from_db()
    end
  end

  def registration_open? do
    get().registration_open
  end

  def embedding_enabled? do
    get().embedding_model_id != nil
  end

  def get_default_mcp_run_cost_limit do
    get().default_mcp_run_cost_limit || Decimal.new("1.0")
  end

  def update_embedding_model(model_id) do
    update(%{embedding_model_id: model_id})
  end

  def update(attrs) do
    result =
      load_from_db()
      |> ServerSettings.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, settings} ->
        settings = Repo.preload(settings, :embedding_model, force: true)
        # coveralls-ignore-next-line
        if @cache_enabled, do: :persistent_term.put(@cache_key, settings)
        {:ok, settings}

      # coveralls-ignore-start
      error ->
        error
        # coveralls-ignore-stop
    end
  end

  def toggle_registration do
    settings = get()
    update(%{registration_open: !settings.registration_open})
  end

  @doc false
  def bust_cache do
    :persistent_term.erase(@cache_key)
  end

  defp load_from_db do
    case Repo.one(from s in ServerSettings, limit: 1) do
      nil ->
        %ServerSettings{}
        |> ServerSettings.changeset(%{registration_open: true})
        |> Repo.insert!(
          on_conflict: :nothing,
          conflict_target: [:singleton]
        )

        # Re-query to handle race: another process may have inserted first
        Repo.one!(from(s in ServerSettings, limit: 1))
        |> Repo.preload(:embedding_model)

      settings ->
        Repo.preload(settings, :embedding_model)
    end
  end

  # coveralls-ignore-start
  defp load_and_cache do
    settings = load_from_db()
    :persistent_term.put(@cache_key, settings)
    settings
  end

  # coveralls-ignore-stop
end

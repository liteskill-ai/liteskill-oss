defmodule Liteskill.Settings do
  @moduledoc """
  The Settings context. Manages server-wide settings using a singleton row pattern.
  """

  alias Liteskill.Repo
  alias Liteskill.Settings.ServerSettings

  def get do
    case Repo.one(ServerSettings) do
      nil ->
        %ServerSettings{}
        |> ServerSettings.changeset(%{registration_open: true})
        |> Repo.insert!()

      settings ->
        settings
    end
  end

  def registration_open? do
    get().registration_open
  end

  def update(attrs) do
    get()
    |> ServerSettings.changeset(attrs)
    |> Repo.update()
  end

  def toggle_registration do
    settings = get()
    update(%{registration_open: !settings.registration_open})
  end
end

defmodule Liteskill.Repo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :liteskill,
    adapter: Ecto.Adapters.Postgres
end

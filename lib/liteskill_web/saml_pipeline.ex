defmodule LiteskillWeb.SamlPipeline do
  @moduledoc """
  Samly pre_session_create pipeline. Called by Samly after a successful
  SAML assertion is received but before the Samly session is created.

  This pipeline is a no-op — actual user provisioning and app session
  creation happen in `SamlAuthController.callback/2` after redirect.
  """

  use Plug.Builder

  plug :noop

  @doc false
  def noop(conn, _opts), do: conn
end

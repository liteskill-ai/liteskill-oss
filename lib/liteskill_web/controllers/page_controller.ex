defmodule LiteskillWeb.PageController do
  @moduledoc false
  use LiteskillWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

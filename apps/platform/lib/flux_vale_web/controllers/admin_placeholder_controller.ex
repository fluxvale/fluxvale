defmodule FluxValeWeb.AdminPlaceholderController do
  use FluxValeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

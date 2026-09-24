defmodule FluxValeWeb.AdminPlaceholderController do
  use FluxValeWeb, :controller

  # coveralls-ignore-start - exists only while ash_admin_domains is empty
  # (ADR-0027 §3); replaced by the real admin surface
  def home(conn, _params) do
    render(conn, :home)
  end

  # coveralls-ignore-stop
end

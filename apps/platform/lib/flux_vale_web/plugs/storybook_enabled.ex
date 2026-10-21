defmodule FluxValeWeb.Plugs.StorybookEnabled do
  @moduledoc """
  The storybook config gate (#178): halts with a 404 when the workshop
  is disabled.

  Mirrors the TestInbox gate: a *runtime* plug, not compile-time route
  mounting — the release is the same image everywhere (ADR-0010), the
  routes always compile in, and `STORYBOOK_ENABLED` (runtime.exs) flips
  the surface on where the fleet attaches storybook.fluxvale.com. Under
  a disabled config the 404 makes /storybook indistinguishable from
  absent.
  """

  import Plug.Conn

  @doc false
  @spec init(term()) :: term()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if Application.get_env(:flux_vale, :storybook_enabled, false) do
      conn
    else
      conn
      |> send_resp(:not_found, "Not Found")
      |> halt()
    end
  end
end

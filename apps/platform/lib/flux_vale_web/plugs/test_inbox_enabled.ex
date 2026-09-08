defmodule FluxValeWeb.Plugs.TestInboxEnabled do
  @moduledoc """
  The TestInbox config gate (#22, ADR-0023 Am. 3): halts with a 404 when
  the surface is disabled.

  Deliberately a *runtime* plug, not `Application.compile_env` route
  mounting (the `dev_routes` pattern): staging must flip the TestInbox on
  for the same release prod runs (ADR-0010's same-image rule), and under
  prod config the 404 makes the routes indistinguishable from absent —
  which is the issue's exit criterion. Runs before the auth plugs so a
  disabled surface never reveals its gating.
  """

  import Plug.Conn

  alias FluxVale.TestInbox

  @doc false
  @spec init(term()) :: term()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if TestInbox.enabled?() do
      conn
    else
      conn
      |> send_resp(:not_found, "Not Found")
      |> halt()
    end
  end
end

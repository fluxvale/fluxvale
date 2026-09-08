defmodule FluxValeWeb.Plugs.TestInboxPreview do
  @moduledoc """
  The TestInbox human UI (#22): Swoosh's stock mailbox preview, mounted
  behind the config + admin gates in the router.

  A wrapper for exactly one reason: `forward` options compile into the
  router, but the storage driver must stay runtime config (the M4
  DB-backed swap, ADR-0023 Am. 3) — so it is injected per-request instead
  of baked into the route.
  """

  @behaviour Plug

  alias FluxVale.TestInbox
  alias Plug.Swoosh.MailboxPreview

  @impl Plug
  @spec init(term()) :: term()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    MailboxPreview.call(conn, storage_driver: TestInbox.storage_driver())
  end
end

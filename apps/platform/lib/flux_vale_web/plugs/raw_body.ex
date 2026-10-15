defmodule FluxValeWeb.Plugs.RawBody do
  @moduledoc """
  Body reader for `Plug.Parsers` that retains the raw request body in
  `conn.assigns.raw_body` for downstream consumers — the v1 port
  (DodoWebhookController's shape).

  Needed by the webhook controller: signature verification requires the
  exact bytes the gateway sent, but Plug.Parsers consumes the body when
  parsing JSON. This reader captures those bytes as a side-effect of
  the normal parse flow.

  ## Cost

  Only invoked for requests that Plug.Parsers actually parses (JSON/
  urlencoded/multipart bodies). GETs and unmatched content-types skip
  it entirely. The stored body is a reference into the same buffer
  Plug.Parsers already holds — no extra copy.

  ## Wiring

  Configured via `Plug.Parsers`' `body_reader:` option in
  `endpoint.ex` (see `FluxValeWeb.Endpoint`).
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
      # Partial reads stream through — Plug.Parsers accumulates and calls
      # again (a raising reader would 500 every large multipart upload).
      {:more, partial, conn} -> {:more, partial, conn}
      # Socket-level failure — not simulatable against a test conn.
      # coveralls-ignore-next-line
      {:error, reason} -> {:error, reason}
    end
  end
end

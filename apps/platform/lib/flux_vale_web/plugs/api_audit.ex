defmodule FluxValeWeb.Plugs.ApiAudit do
  @moduledoc """
  One audit row per PAT-authenticated API call (#360 slice 5,
  ADR-0019 Am. 1) — the `/api/v1` routes and the `/mcp` transport
  (#361): method, path, status — enough to answer "what did this
  token do", never the token value.

  Registers the write on `register_before_send`, so the FINAL
  response status is what lands — 200s, policy 403s, scope 403s,
  429s, 404s, one code path. One registration per conn = one row per
  request, a pure append with no arithmetic shared with the rate
  limiter's window counters (separate stores, no double-count
  surface). Mechanism-inherent gap: a crash that escapes
  Plug.Conn's send path never runs `register_before_send` —
  rendered errors are audited, crash-500s are not.

  Mounted right after Authenticate, BEFORE the gates: a conn that
  halts at a later plug still gets its row — including the
  AccessRule-denied 401 (Authenticate nils `current_user` but leaves
  `api_pat` assigned). Session-authenticated and unauthenticated
  calls write NOTHING: scopes and metering are PAT concepts, and an
  anonymous call has no token to attribute.

  The write is the guarded synchronous insert
  (`FluxVale.Api.record_audit_event/1` — a failure logs, never 500s
  the request): no async supervisor whose tasks the suite would have
  to await, and every caller sees the row deterministically.
  """

  import Plug.Conn

  alias FluxVale.Api

  # The classic URL bound, matching the resource constraint —
  # defense-in-depth (real routes are uuid-short).
  @path_cap 2048

  @doc false
  @spec init(keyword) :: keyword
  def init(opts), do: opts

  @doc """
  Registers the audit write for PAT-authenticated calls; every other
  conn passes through untouched.
  """
  @spec call(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.assigns[:api_pat] do
      nil -> conn
      pat -> register(conn, pat)
    end
  end

  defp register(conn, pat) do
    register_before_send(conn, fn conn ->
      Api.record_audit_event(%{
        kind: :request,
        personal_access_token_id: pat.id,
        method: conn.method,
        # request_path is the FULL path WITHOUT the query string (that
        # is conn.query_string, a separate field) — the no-query
        # guarantee is structural, not filtering.
        path: path(conn.request_path),
        status_code: conn.status
      })

      conn
    end)
  end

  defp path(request_path) do
    String.slice(request_path, 0, @path_cap)
  end
end

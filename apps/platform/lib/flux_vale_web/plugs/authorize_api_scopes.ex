defmodule FluxValeWeb.Plugs.AuthorizeApiScopes do
  @moduledoc """
  The `/api/v1` scope gate (#360): after actor resolution, a PAT must
  hold the route's required scope; session auth stays read-only.

  The 401/403 contract (RequireActor's split, extended):

  - **403** — PAT-authenticated but the token's scopes do not cover
    the route (`FluxVale.Api.Scopes.required_scope/2` says what the
    route needs; `grants?/2` says whether the token has it). An
    unmapped path is also 403: deny-by-default for token callers.
    The detail string names the missing scope, so these 403s are
    distinguishable from Ash policy 403s.
  - **401** — session-authenticated but the method is a write: the
    session cookie cannot drive the machine API (CSRF posture,
    ADR-0019 Am. 1). Reads pass — resource policies still bite
    downstream (dev browsing, swaggerui).

  Error documents mirror RequireActor's shape exactly: one JSON:API
  error object, `application/vnd.api+json`, charset-free.
  """

  import Plug.Conn

  alias FluxVale.Api.Scopes

  @session_write_detail "writes on /api/v1 require a personal access token"

  @doc false
  @spec init(keyword) :: keyword
  def init(opts), do: opts

  @doc """
  Halts with 403 (scope-denied token) or 401 (session write) per the
  contract above; passes everything else through.
  """
  @spec call(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def call(conn, _opts) do
    segments = api_segments(conn.path_info)

    cond do
      swaggerui?(segments) ->
        conn

      pat = conn.assigns[:api_pat] ->
        gate_pat(conn, pat, segments)

      conn.assigns[:current_user] ->
        gate_session(conn, conn.method)

      true ->
        conn
    end
  end

  defp gate_pat(conn, pat, segments) do
    case Scopes.required_scope(conn.method, segments) do
      {:ok, :any} ->
        conn

      {:ok, scope} ->
        if Scopes.grants?(pat.scopes, scope) do
          conn
        else
          forbidden(conn, "token is missing the required scope #{scope}")
        end

      # Deny-by-default (#360): a token caller on a path the table
      # does not know gets 403, never a fallthrough.
      :error ->
        forbidden(conn, "no scope grants access to this path")
    end
  end

  # Session auth on /api/v1 is read-only (CSRF: the browser cookie
  # must never drive machine writes — ADR-0019 Am. 1). Reads pass and
  # resource policies stay the authority downstream.
  defp gate_session(conn, method) when method in ["GET", "HEAD"], do: conn

  defp gate_session(conn, _write_method), do: unauthorized(conn, @session_write_detail)

  defp swaggerui?(["swaggerui" | _subpath]), do: true
  defp swaggerui?(_segments), do: false

  # The plug mounts only in the /api/v1 pipeline; the unprefixed arm
  # keeps a direct (test) invocation honest instead of exploding.
  defp api_segments(["api", "v1" | rest]), do: rest
  defp api_segments(other), do: other

  defp forbidden(conn, detail) do
    error_document(conn, 403, "Forbidden", detail)
  end

  defp unauthorized(conn, detail) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> error_document(401, "Unauthorized", detail)
  end

  # RequireActor's exact rendering posture: JSON:API error document,
  # bare media type with no charset (byte-identical to every other
  # API response).
  defp error_document(conn, status, title, detail) do
    body =
      Jason.encode!(%{
        errors: [%{status: Integer.to_string(status), title: title, detail: detail}]
      })

    conn
    |> put_resp_content_type("application/vnd.api+json", nil)
    |> resp(status, body)
    |> halt()
  end
end

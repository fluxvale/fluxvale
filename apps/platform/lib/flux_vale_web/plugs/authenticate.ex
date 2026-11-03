defmodule FluxValeWeb.Plugs.Authenticate do
  @moduledoc """
  Resolves the current user — bearer-PAT-first, session-fallback
  (#360; the JWT bearer of #24 lives on only outside /api/v1).

  Bearer PAT: a value starting `fvpat_` resolves through the
  `personal_access_tokens` table — the SHA-256 hash lookup must find
  a row that is neither revoked nor expired. On success the token's
  user is assigned (`current_user`) and the row itself (`api_pat`,
  the boundary plug's scope source). The raw value is never stored
  or logged; `last_used_at` is touched at most once a minute.

  JWT bearer: only consulted OFF `/api/v1` (test-inbox, admin) — on
  `/api/v1` a JWT bearer is refused outright. The #23 JWT PAT mint is
  gone and zero were issued publicly, so no client exists to break;
  sessions still authenticate `/api/v1` reads through the cookie
  fallback (ADR-0019 Am. 1: no long-lived signed machine credential).

  Session: v2 sessions are token-backed (`store_in_session/2`), so the
  fallback also resolves through the token store — unlike v1's raw
  `user_id` lookup, which bypassed revocation. A revoked session token
  severs API use too (the deliberately ported upgrade, #24).

  An invalid bearer falls back to the session, exactly as in v1: the
  header wins when it authenticates, absence or failure does not.

  #26 (ADR-0023 Am. 1): the AccessRule check at token presentation —
  bearer and session both resolve here, so both are gated in one place;
  a removed rule severs access within TTL, not at token expiry. A denied
  user is dropped before `set_actor` so RequireActor answers 401.
  Check-based, not token-based: token rows stay — revoking tokens
  outright stays the admin's separate hammer.
  """

  alias AshAuthentication.Plug.Helpers
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRules

  require Logger

  @pat_prefix "fvpat_"
  # last_used_at granularity — coarser stamps buy nothing (nothing
  # displays finer than "recently") and the write is per-request.
  @last_used_granularity_seconds 60

  @doc false
  @spec init(keyword) :: keyword
  def init(opts), do: opts

  @doc """
  Resolves the current user (bearer-PAT-first, session-fallback),
  assigns `conn.assigns.current_user`, and sets the Ash actor for
  ash_json_api.
  """
  @spec call(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn
    |> from_bearer()
    |> from_session()
    |> enforce_access_rules()
    |> set_actor()
  end

  defp from_bearer(conn) do
    if bearer_token?(conn) do
      conn
      |> canonicalize_bearer_scheme()
      |> resolve_bearer()
    else
      conn
    end
  end

  # PAT bearers resolve everywhere; the JWT bearer only off /api/v1
  # (see the moduledoc — ADR-0019 Am. 1).
  defp resolve_bearer(conn) do
    case pat_bearer_value(conn) do
      nil ->
        if api_v1?(conn) do
          # A JWT (or any non-PAT value) on /api/v1 is refused — no
          # fallback into the JWT verifier. Failure posture is the
          # shared one: no current_user from this branch, session
          # still consulted below.
          conn
        else
          Helpers.retrieve_from_bearer(conn, :flux_vale)
        end

      raw ->
        from_pat(conn, raw)
    end
  end

  defp from_pat(conn, raw) do
    # System lookup (seeds/janitor posture): the plug has no actor to
    # authorize — the raw-value/hash match IS the proof, revoked and
    # expired are checked right here, and downstream policies bite
    # with the resolved actor.
    hash = PersonalAccessToken.token_hash(raw)

    case PersonalAccessToken.get_by_token_hash(hash, authorize?: false) do
      {:ok, pat} when is_nil(pat.revoked_at) ->
        if DateTime.after?(pat.expires_at, DateTime.utc_now()) do
          user = Ash.get!(User, pat.user_id, authorize?: false)

          conn
          |> Plug.Conn.assign(:current_user, user)
          |> Plug.Conn.assign(:api_pat, pat)
          |> touch_last_used(pat)
        else
          conn
        end

      _revoked_or_missing ->
        conn
    end
  end

  # RFC 7235: auth-scheme names are case-insensitive; the ash_authentication
  # helper parses only the canonical "Bearer " prefix — normalize before it
  # sees the header (CodeRabbit, #44). The PAT branch matches on the same
  # canonical prefix.
  defp bearer_token?(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> Enum.any?(&bearer_scheme?/1)
  end

  defp bearer_scheme?(header) do
    header
    |> String.downcase()
    |> String.starts_with?("bearer ")
  end

  defp canonicalize_bearer_scheme(conn) do
    req_headers =
      Enum.map(conn.req_headers, fn
        {"authorization", "bearer" <> rest} -> {"authorization", "Bearer" <> rest}
        header -> header
      end)

    %{conn | req_headers: req_headers}
  end

  # The bearer value when it is a PAT, nil otherwise (JWT, garbage, or
  # absent).
  defp pat_bearer_value(conn) do
    authorization_headers = Plug.Conn.get_req_header(conn, "authorization")

    Enum.find_value(authorization_headers, fn
      "Bearer " <> rest -> if String.starts_with?(rest, @pat_prefix), do: rest
      _other_header -> nil
    end)
  end

  defp api_v1?(%Plug.Conn{path_info: ["api", "v1" | _rest]}), do: true
  defp api_v1?(_other_conn), do: false

  # Best-effort telemetry write: a failure is logged and swallowed — a
  # failed touch must never 500 an otherwise-authenticated request.
  defp touch_last_used(conn, pat) do
    if stale_last_used?(pat.last_used_at) do
      case PersonalAccessToken.touch_last_used(pat, authorize?: false) do
        {:ok, _pat} ->
          conn

        # coveralls-ignore-start - touch failure = DB outage mid-auth;
        # the request proceeds on the already-proven hash match (AGENTS:
        # DB-down is a cluster-level concern, not exercisable in-process)
        {:error, error} ->
          Logger.warning("PAT last_used touch failed for #{pat.id}: #{Exception.message(error)}")
          conn
          # coveralls-ignore-stop
      end
    else
      conn
    end
  end

  defp stale_last_used?(nil), do: true

  defp stale_last_used?(last_used_at) do
    DateTime.diff(DateTime.utc_now(), last_used_at) >= @last_used_granularity_seconds
  end

  # Only falls back when the bearer path resolved nothing — a successful
  # bearer auth must not be re-resolved from whatever session rode along.
  defp from_session(%Plug.Conn{assigns: %{current_user: user}} = conn) when not is_nil(user),
    do: conn

  defp from_session(conn), do: Helpers.retrieve_from_session(conn, :flux_vale)

  defp enforce_access_rules(%Plug.Conn{assigns: %{current_user: user}} = conn)
       when not is_nil(user) do
    # User-level gate (#285 T3): any verified address passing the
    # allowlist keeps the bearer (or session) alive.
    case AccessRules.ensure_allowed_user(user) do
      :ok -> conn
      {:error, :not_allowed} -> Plug.Conn.assign(conn, :current_user, nil)
    end
  end

  defp enforce_access_rules(conn), do: conn

  defp set_actor(conn),
    do: Ash.PlugHelpers.set_actor(conn, conn.assigns[:current_user])
end

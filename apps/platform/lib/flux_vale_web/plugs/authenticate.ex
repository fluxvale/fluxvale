defmodule FluxValeWeb.Plugs.Authenticate do
  @moduledoc """
  Resolves the current user — bearer-PAT-first, session-fallback
  (#360; the JWT bearer of #24 lives on only outside /api/v1).

  Bearer token: a value starting `fvpat_` (PAT) or `fvoat_` (OAuth
  access token) resolves through the `personal_access_tokens` table —
  the SHA-256 hash lookup must find a row that is neither revoked nor
  expired AND whose kind matches the prefix. On success the token's
  user is assigned (`current_user`) and the row itself (`api_pat`,
  the boundary plug's scope source). The raw value is never stored
  or logged; `last_used_at` is touched at most once a minute.
  Refresh tokens (`fvort_`) never authenticate a request.

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
  @oauth_access_prefix "fvoat_"
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

  # PAT and OAuth access bearers resolve everywhere; the JWT bearer
  # only off /api/v1 (see the moduledoc — ADR-0019 Am. 1).
  defp resolve_bearer(conn) do
    case token_bearer_value(conn) do
      nil ->
        if api_v1?(conn) do
          # A JWT (or any non-token value) on /api/v1 is refused — no
          # fallback into the JWT verifier. Failure posture is the
          # shared one: no current_user from this branch, session
          # still consulted below.
          conn
        else
          Helpers.retrieve_from_bearer(conn, :flux_vale)
        end

      {raw, kind} ->
        from_token(conn, raw, kind)
    end
  end

  defp from_token(conn, raw, expected_kind) do
    # System lookup (seeds/janitor posture): the plug has no actor to
    # authorize — the raw-value/hash match IS the proof, revoked and
    # expired are checked right here, and downstream policies bite
    # with the resolved actor.
    hash = PersonalAccessToken.token_hash(raw)

    case PersonalAccessToken.get_by_token_hash(hash, authorize?: false) do
      {:ok, token} when is_nil(token.revoked_at) ->
        # The prefix is a claim, not the proof: a refresh token
        # presented as an access token must not authenticate, and a
        # PAT prefix on an OAuth row is a mismatch too. A minted PAT
        # child (#772) also rides its parent's liveness: revoking the
        # credential that minted it severs the whole chain on the next
        # presentation, not only when the child's own TTL ends.
        if token.kind == expected_kind and lineage_live?(token) do
          resolve_user(conn, token)
        else
          conn
        end

      _revoked_or_missing ->
        conn
    end
  end

  # Walk the derivation chain (`minted_parent_id`) to the root. A
  # revoked or expired ancestor refuses every child below it. Tokens
  # minted by the panel or the device flow carry no parent and pass
  # on their own row alone. The chain cannot cycle: a parent row is
  # created before the child that names it.
  defp lineage_live?(pat) do
    case pat.metadata do
      %{"minted_parent_id" => parent_id} when is_binary(parent_id) ->
        case PersonalAccessToken.get(parent_id, authorize?: false) do
          {:ok, parent} when is_nil(parent.revoked_at) ->
            DateTime.after?(parent.expires_at, DateTime.utc_now()) and lineage_live?(parent)

          _missing_or_revoked ->
            false
        end

      _root ->
        true
    end
  end

  # A live, unrevoked token still needs its user: expiry first, then
  # the non-bang fetch — see attach_user for the never-500 posture.
  defp resolve_user(conn, pat) do
    if DateTime.after?(pat.expires_at, DateTime.utc_now()) do
      attach_user(conn, pat)
    else
      conn
    end
  end

  defp attach_user(conn, pat) do
    case Ash.get(User, pat.user_id, authorize?: false) do
      {:ok, user} ->
        conn
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:api_pat, pat)
        |> touch_last_used(pat)

      # coveralls-ignore-start - user-delete race: the FK is
      # on_delete: :delete_all, so a live token row cannot outlive
      # its user through any action or seed — only a delete landing
      # between the token read and this fetch lands here. Behaves
      # like a failed lookup (no current_user from this branch,
      # session consulted below): the file's never-500 posture
      # mid-Authenticate.
      _deleted_mid_auth ->
        conn

        # coveralls-ignore-stop
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

  # Any casing of the scheme token — "BEARER", "BeArEr", … — rewrites to
  # canonical "Bearer" before the parsers below see the header: they all
  # match on the exact canonical prefix, so a case-sensitive rewrite would
  # leave anything but all-lowercase uncanonicalized (and 401 a valid
  # token). "Bearer" itself (and any non-bearer scheme) passes through
  # unchanged.
  defp canonicalize_bearer_scheme(conn) do
    req_headers =
      Enum.map(conn.req_headers, fn
        {"authorization", header} -> {"authorization", canonical_scheme(header)}
        header -> header
      end)

    %{conn | req_headers: req_headers}
  end

  defp canonical_scheme(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, rest] when scheme != "Bearer" ->
        if String.downcase(scheme) == "bearer" do
          "Bearer " <> rest
        else
          header
        end

      # Already canonical, or not scheme-shaped ("bearer" with no
      # value, a bare token) — downstream parsing decides.
      _canonical_or_shapeless ->
        header
    end
  end

  # The bearer value + its expected kind when it is a PAT or OAuth
  # access token, nil otherwise (JWT, refresh token, garbage, absent).
  defp token_bearer_value(conn) do
    authorization_headers = Plug.Conn.get_req_header(conn, "authorization")

    Enum.find_value(authorization_headers, fn
      "Bearer " <> rest -> bearer_kind(rest)
      _other_header -> nil
    end)
  end

  defp bearer_kind(rest) do
    cond do
      String.starts_with?(rest, @pat_prefix) -> {rest, :pat}
      String.starts_with?(rest, @oauth_access_prefix) -> {rest, :oauth_access}
      true -> nil
    end
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

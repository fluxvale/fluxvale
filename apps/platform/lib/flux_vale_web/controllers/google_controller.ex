defmodule FluxValeWeb.GoogleController do
  @moduledoc """
  The Google OIDC hops for sign-in (#642, plan §3.2,
  ADR-0003 Am. 4): `GET /auth/google` builds the assent authorize
  request (PKCE S256 + nonce), parks the `session_params` plus the
  validated `return_to` in the Phoenix session, and redirects to
  Google; `GET /auth/google/callback` exchanges the code and resolves
  the verified claims through `Identity.sign_in_with_google/1` — the
  SAME admission ladder the email arm runs. The session write is
  `store_in_session` in this one server-side hop: the token never
  rides a URL (the callback's code is single-use, bound to our client
  id and PKCE verifier, and worthless once exchanged).

  Both hops refuse unless the `:google_sign_in` flag is on AND
  credentials are configured — the same predicate the button renders
  under, so the arm is invisible everywhere it can't work. Both are
  per-IP throttled (`GoogleRateLimit`, the D-abuse window) with a
  browser-shaped refusal — never a bare 429.

  The authorize round trip is single-use: the callback consumes the
  parked `session_params` regardless of outcome, so a replayed
  callback dies at state validation with no outbound token request.
  """

  use FluxValeWeb, :controller

  alias AshAuthentication.Plug.Helpers
  alias FluxVale.Identity
  alias FluxVale.Identity.GoogleOIDC
  alias FluxVale.Ops.FeatureFlags
  alias FluxValeWeb.AuthFlow
  alias FluxValeWeb.Plugs.GoogleRateLimit
  alias FluxValeWeb.ReturnPath

  require Logger

  @round_trip "google_oidc_round_trip"
  # Assent-level failures all answer with one copy (the controller's
  # error set, plan §3.3): the reason differs, the visitor's next
  # step never does.
  @oidc_failed_copy "Google sign-in didn't complete. Use an email code."

  @doc """
  The authorize hop: parks the round-trip state and redirects to
  Google. Assent fetches discovery here, so the call can fail — the
  copy then names the email-code fallback (plan §5).
  """
  def authorize(conn, params) do
    cond do
      not GoogleRateLimit.allow?(conn) ->
        throttled(conn)

      not arm_live?() ->
        unavailable(conn)

      true ->
        start_round_trip(conn, params)
    end
  end

  @doc """
  The callback hop: consumes the round-trip state (always — single
  use, success or failure), exchanges the code, resolves the claims.
  Every failure lands on `/sign-in` with `AuthFlow`-owned copy.
  """
  def callback(conn, params) do
    # Consume BEFORE anything else (plan §3.2): a replayed callback
    # must die at state validation with no outbound token request.
    round_trip = get_session(conn, @round_trip)
    conn = delete_session(conn, @round_trip)

    cond do
      not GoogleRateLimit.allow?(conn) ->
        throttled(conn)

      not arm_live?() ->
        unavailable(conn)

      true ->
        exchange(conn, params, round_trip)
    end
  end

  defp start_round_trip(conn, params) do
    return_to = ReturnPath.safe(params["return_to"])

    case GoogleOIDC.authorize_url(callback_url()) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(@round_trip, %{params: session_params, return_to: return_to})
        |> redirect(external: url)

      {:error, reason} ->
        oidc_failed(conn, reason, :authorize)
    end
  end

  # The parked round trip, replayed against assent: state/PKCE/nonce
  # all validate inside the exchange, and the claims resolve through
  # the admission ladder (AuthFlow maps the outcome to copy).
  defp exchange(conn, params, %{params: session_params, return_to: return_to}) do
    case GoogleOIDC.callback(params, session_params, callback_url()) do
      {:ok, claims} ->
        resolve(conn, claims, return_to)

      {:error, reason} ->
        oidc_failed(conn, reason, :callback)
    end
  end

  # No parked round trip — a cold callback, or a replay after the
  # consume above. Nothing to validate against; the honest failure.
  defp exchange(conn, _params, _absent) do
    conn
    |> put_flash(:error, @oidc_failed_copy)
    |> redirect(to: ~p"/sign-in")
  end

  defp resolve(conn, claims, return_to) do
    outcome = Identity.sign_in_with_google(claims)

    case AuthFlow.google_outcome(outcome) do
      {:ok, user, token} ->
        # SessionController.sign_in's shape (#219): the token rides
        # the user metadata into the session store, the pending
        # email-flow address (if any) dies with the step it belonged
        # to, and the flash names the door just used.
        user = Ash.Resource.put_metadata(user, :token, token)

        conn
        |> delete_session("sign_in_email")
        |> Helpers.store_in_session(user)
        |> put_flash(:info, "Signed in with Google.")
        |> redirect(to: return_to || ~p"/")

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ReturnPath.sign_in_path(return_to))
    end
  end

  # The render predicate, shared with the button (D-flag): live only
  # with the flag row on AND credentials present — fail-closed both
  # ways, so dev/test/local default to off.
  defp arm_live? do
    FeatureFlags.enabled?(:google_sign_in) and GoogleOIDC.configured?()
  end

  defp unavailable(conn) do
    conn
    |> put_flash(:error, AuthFlow.google_unavailable())
    |> redirect(to: ~p"/sign-in")
  end

  defp throttled(conn) do
    conn
    |> put_flash(:error, AuthFlow.google_throttled())
    |> redirect(to: ~p"/sign-in")
  end

  # Assent-level failure (network, bad state, token exchange) — the
  # controller's error set (plan §3.3): the copy names the always-on
  # email fallback, and the reason lands server-side only, PII-free
  # (assent errors carry URLs and OAuth error codes, never claims).
  defp oidc_failed(conn, reason, hop) do
    Logger.warning("Google OIDC #{hop} hop failed: #{inspect(reason)}")

    conn
    |> put_flash(:error, @oidc_failed_copy)
    |> redirect(to: ~p"/sign-in")
  end

  # Plan §6: the redirect URI derives from the endpoint's own :url
  # config (PHX_HOST/scheme/port) — dev/test's http localhost shape,
  # prod's https host. No env var to drift.
  defp callback_url do
    FluxValeWeb.Endpoint.url() <> "/auth/google/callback"
  end
end

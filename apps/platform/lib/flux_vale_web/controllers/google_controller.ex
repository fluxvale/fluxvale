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

  Both hops refuse unless `GoogleOIDC.arm_available?/0` — the one
  predicate the button also renders under, so the arm is invisible
  everywhere it can't work. Both are per-IP throttled
  (`GoogleRateLimit`, the D-abuse window) with a browser-shaped
  refusal — never a bare 429. Failure arms keep the round trip's
  destination (plan §5): the email fallback never forgets where the
  visitor was going.

  The authorize round trip is single-use: the callback consumes the
  parked `session_params` regardless of outcome, so a replayed
  callback dies at state validation with no outbound token request.
  """

  use FluxValeWeb, :controller

  alias AshAuthentication.Plug.Helpers
  alias FluxVale.Identity
  alias FluxVale.Identity.GoogleOIDC
  alias FluxValeWeb.AuthFlow
  alias FluxValeWeb.Plugs.GoogleRateLimit
  alias FluxValeWeb.ReturnPath

  require Logger

  @round_trip "google_oidc_round_trip"
  # Assent-level failures and malformed/absent round trips all answer
  # with one copy (the controller's error set, plan §3.3): the reason
  # differs, the visitor's next step never does.
  @oidc_failed_copy "Google sign-in didn't complete. Use an email code."

  @doc """
  The authorize hop: parks the round-trip state and redirects to
  Google. Assent fetches discovery here, so the call can fail — the
  copy then names the email-code fallback (plan §5).
  """
  def authorize(conn, params) do
    return_to = ReturnPath.safe(params["return_to"])

    cond do
      not GoogleRateLimit.allow?(conn) ->
        throttled(conn, return_to)

      not GoogleOIDC.arm_available?() ->
        unavailable(conn, return_to)

      true ->
        start_round_trip(conn, return_to)
    end
  end

  @doc """
  The callback hop: consumes the round-trip state (always — single
  use, success or failure), exchanges the code, resolves the claims.
  Every failure lands on the email step with `AuthFlow`-owned copy
  and the round trip's destination still attached.
  """
  def callback(conn, params) do
    # Consume BEFORE anything else (plan §3.2): a replayed callback
    # must die at state validation with no outbound token request.
    round_trip = get_session(conn, @round_trip)
    conn = delete_session(conn, @round_trip)

    return_to =
      case round_trip do
        %{return_to: parked} -> parked
        _absent -> nil
      end

    cond do
      not GoogleRateLimit.allow?(conn) ->
        throttled(conn, return_to)

      not GoogleOIDC.arm_available?() ->
        unavailable(conn, return_to)

      true ->
        exchange(conn, params, round_trip)
    end
  end

  defp start_round_trip(conn, return_to) do
    case GoogleOIDC.authorize_url(callback_url()) do
      {:ok, %{url: url, session_params: session_params}} ->
        # One round trip per session: a second tab's authorize
        # overwrites this slot and the first tab's callback then dies
        # at state validation onto the email door — the accepted
        # trade-off of the single-use design (plan §3.2).
        conn
        |> put_session(@round_trip, %{params: session_params, return_to: return_to})
        |> redirect(external: url)

      {:error, reason} ->
        oidc_failed(conn, reason, :authorize, return_to)
    end
  end

  # The parked round trip, replayed against assent: state/PKCE/nonce
  # all validate inside the exchange, and the claims resolve through
  # the admission ladder (AuthFlow maps the outcome to copy).
  defp exchange(conn, params, %{params: session_params, return_to: return_to}) do
    case callback_params(params) do
      %{"code" => code, "state" => state} ->
        exchange_code(conn, code, state, session_params, return_to)

      nil ->
        oidc_refused(conn, return_to)
    end
  end

  # No parked round trip — a cold callback, or a replay after the
  # consume above. Nothing to validate against; the honest failure
  # (there is no parked destination to keep).
  defp exchange(conn, _params, _absent) do
    oidc_refused(conn, nil)
  end

  defp exchange_code(conn, code, state, session_params, return_to) do
    case GoogleOIDC.callback(%{"code" => code, "state" => state}, session_params, callback_url()) do
      {:ok, claims} ->
        resolve(conn, claims, return_to)

      {:error, reason} ->
        oidc_failed(conn, reason, :callback, return_to)
    end
  end

  # Only the two params assent reads cross into the exchange, and only
  # as binaries: repeated or indexed form keys arrive as lists/maps
  # (`?state[]=x`, `?code[k]=v`) and must die at the honest copy —
  # assent's constant-time compare and URI encoding are binary-only,
  # and an anonymous crash surface is exactly what SignInController
  # and SessionController guard on their own inputs (#219).
  defp callback_params(%{"code" => code, "state" => state})
       when is_binary(code) and code != "" and is_binary(state) and state != "" do
    %{"code" => code, "state" => state}
  end

  defp callback_params(_malformed), do: nil

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
        # Belt-and-braces: the value was ReturnPath.safe at authorize
        # time and rides a signed cookie, but the house posture is
        # re-validate at every redirect hop.
        |> redirect(to: ReturnPath.safe(return_to) || ~p"/")

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ReturnPath.sign_in_path(return_to))
    end
  end

  defp unavailable(conn, return_to) do
    conn
    |> put_flash(:error, AuthFlow.google_unavailable())
    |> redirect(to: ReturnPath.sign_in_path(return_to))
  end

  defp throttled(conn, return_to) do
    conn
    |> put_flash(:error, AuthFlow.google_throttled())
    |> redirect(to: ReturnPath.sign_in_path(return_to))
  end

  # Malformed callback input: the same honest answer as an absent
  # round trip — nothing to validate, nothing leaked, one copy.
  defp oidc_refused(conn, return_to) do
    conn
    |> put_flash(:error, @oidc_failed_copy)
    |> redirect(to: ReturnPath.sign_in_path(return_to))
  end

  # Assent-level failure (network, bad state, token exchange) — the
  # controller's error set (plan §3.3): the copy names the always-on
  # email fallback; the reason lands server-side only, BOUNDED — an
  # error struct can embed an attacker-supplied response body, so the
  # inspect limits cap the log line (claims never ride it).
  defp oidc_failed(conn, reason, hop, return_to) do
    Logger.warning(
      "Google OIDC #{hop} hop failed: #{inspect(reason, limit: 20, printable_limit: 200)}"
    )

    conn
    |> put_flash(:error, @oidc_failed_copy)
    |> redirect(to: ReturnPath.sign_in_path(return_to))
  end

  # Plan §6: the redirect URI derives from the endpoint's own :url
  # config (PHX_HOST/scheme/port) — dev/test's http localhost shape,
  # prod's https host. No env var to drift.
  defp callback_url do
    FluxValeWeb.Endpoint.url() <> "/auth/google/callback"
  end
end

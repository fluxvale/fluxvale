defmodule FluxValeWeb.SessionController do
  @moduledoc """
  The session-write side of passwordless sign-in (#21): a POST to
  `/auth/session` carries the proof of inbox ownership in its body —
  never a URL (ADR-0003's magic-link lesson: URLs leak through
  referrers, scanners, and logs). Two proof shapes reach this seam:

    * `token` — the connected LiveView's one-shot `phx-trigger-action`
      POST after its in-process verify minted the standard token.
    * `email` + `code` — the native fallback's verify POST (#219): the
      code, not a token, because the no-WebSocket path never ran the
      LiveView's verify. Same operation, same guarantees; the mint and
      the store happen in one hop.

  #26: the AccessRule gate before the session write — this controller
  accepts any valid token, including one minted before a rule was
  removed; the mint gate in VerifyAuthCode closes the sign-in flow, this
  closes re-entry with a stale token. The code arm re-runs the same gate
  inside `VerifyAuthCode`.

  The POST may carry a `return_to` (the sign-in LiveView rides it
  through in its body, #462): the visitor lands back on the local path
  they came from instead of the default page. The value is never
  trusted — `ReturnPath.safe/1` re-validates it here, so a crafted
  non-local target silently falls back to `/`. A failed session write
  re-links sign-in with the same return path, so the retry keeps the
  destination too.

  A failed verify answers on the step it belongs to (`AuthFlow` owns
  the copy): a wrong code stays on `/sign-in/code`, and a terminal
  refusal (lockout, a rule landing mid-flow, an invitation wall)
  returns to the email step — clearing the pending address so the code
  page cannot re-open a dead flow.
  """

  use FluxValeWeb, :controller

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias FluxVale.Identity
  alias FluxVale.Ops.AccessRules
  alias FluxValeWeb.AuthFlow
  alias FluxValeWeb.ReturnPath

  def create(conn, %{"token" => token} = params) when is_binary(token) and token != "" do
    return_to = ReturnPath.safe(params["return_to"])

    with {:ok, claims, resource} <- Jwt.verify(token, :flux_vale),
         {:ok, user} <- AshAuthentication.subject_to_user(claims["sub"], resource),
         # User-level gate (#285 T3) — the token may present any verified
         # address of the account
         :ok <- AccessRules.ensure_allowed_user(user) do
      sign_in(conn, user, token, return_to)
    else
      _error -> failed(conn, return_to)
    end
  end

  # #219: the native verify — the no-WebSocket (or no-JavaScript) path
  # never ran the LiveView's in-process verify, so the code arrives here
  # and the session write happens in one hop. Absent/blank values fall
  # through to the generic failure, never a crash.
  def create(conn, %{"email" => email, "code" => code} = params)
      when is_binary(email) and email != "" and is_binary(code) and code != "" do
    return_to = ReturnPath.safe(params["return_to"])
    outcome = Identity.verify_auth_code(email, code)

    case AuthFlow.verify_outcome(outcome) do
      {:ok, user, token} ->
        sign_in(conn, user, token, return_to)

      {:code, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ReturnPath.code_path(return_to))

      {:email, message} ->
        conn
        |> delete_session("sign_in_email")
        |> put_flash(:error, message)
        |> redirect(to: ReturnPath.sign_in_path(return_to))
    end
  end

  def create(conn, params) do
    failed(conn, ReturnPath.safe(params["return_to"]))
  end

  @doc """
  Signs out (#74): revokes the session's tokens (the token store, not
  just the cookie — API use rides the same tokens) and clears the
  session. Idempotent: no session means there is nothing to revoke.

  Lands on the landing page (#473) — someone who just left their
  account gets the front door, not the sign-in form.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> Helpers.revoke_session_tokens(:flux_vale)
    |> clear_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end

  defp sign_in(conn, user, token, return_to) do
    user = Ash.Resource.put_metadata(user, :token, token)

    conn
    |> delete_session("sign_in_email")
    |> Helpers.store_in_session(user)
    |> put_flash(:info, "Signed in.")
    |> redirect(to: return_to || ~p"/")
  end

  defp failed(conn, return_to) do
    conn
    |> put_flash(:error, "Sign-in failed. Request a new code.")
    |> redirect(to: ReturnPath.sign_in_path(return_to))
  end
end

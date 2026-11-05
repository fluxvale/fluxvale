defmodule FluxValeWeb.SessionController do
  @moduledoc """
  The session-write side of the LiveView sign-in flow (#21): the
  one-shot POST from `AuthLive.SignIn` carries the freshly minted token
  in its body; this controller resolves it to a user and stores the
  framework-standard session (`AshAuthentication.Plug.Helpers`).

  The token is never accepted from a URL — POST body only (ADR-0003's
  magic-link lesson: URLs leak through referrers, scanners, and logs).

  #26: the AccessRule gate before the session write — this controller
  accepts any valid token, including one minted before a rule was
  removed; the mint gate in VerifyAuthCode closes the sign-in flow, this
  closes re-entry with a stale token.

  The POST may carry a `return_to` (the sign-in LiveView rides it
  through in its body, #462): on success the visitor lands back on the
  local path they came from instead of the default page. The value is
  never trusted — `ReturnPath.safe/1` re-validates it here, so a
  crafted non-local target silently falls back to `/`.
  """

  use FluxValeWeb, :controller

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias FluxVale.Ops.AccessRules
  alias FluxValeWeb.ReturnPath

  def create(conn, %{"token" => token} = params) do
    return_to = ReturnPath.safe(params["return_to"])

    with {:ok, claims, resource} <- Jwt.verify(token, :flux_vale),
         {:ok, user} <- AshAuthentication.subject_to_user(claims["sub"], resource),
         # User-level gate (#285 T3) — the token may present any verified
         # address of the account
         :ok <- AccessRules.ensure_allowed_user(user),
         user <- Ash.Resource.put_metadata(user, :token, token) do
      conn
      |> Helpers.store_in_session(user)
      |> put_flash(:info, "Signed in.")
      |> redirect(to: return_to || ~p"/")
    else
      _error ->
        conn
        |> put_flash(:error, "Sign-in failed. Request a new code.")
        |> redirect(to: ~p"/sign-in")
    end
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
end

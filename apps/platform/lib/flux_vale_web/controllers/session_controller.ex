defmodule FluxValeWeb.SessionController do
  @moduledoc """
  The session-write side of the LiveView sign-in flow (#21): the
  one-shot POST from `AuthLive.SignIn` carries the freshly minted token
  in its body; this controller resolves it to a user and stores the
  framework-standard session (`AshAuthentication.Plug.Helpers`).

  The token is never accepted from a URL — POST body only (ADR-0003's
  magic-link lesson: URLs leak through referrers, scanners, and logs).
  """

  use FluxValeWeb, :controller

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers

  def create(conn, %{"token" => token}) do
    with {:ok, claims, resource} <- Jwt.verify(token, :flux_vale),
         {:ok, user} <- AshAuthentication.subject_to_user(claims["sub"], resource),
         user <- Ash.Resource.put_metadata(user, :token, token) do
      conn
      |> Helpers.store_in_session(user)
      |> put_flash(:info, "Signed in.")
      |> redirect(to: ~p"/")
    else
      _error ->
        conn
        |> put_flash(:error, "Sign-in failed — request a new code.")
        |> redirect(to: ~p"/sign-in")
    end
  end
end

defmodule FluxValeWeb.SignInController do
  @moduledoc """
  The native POST door for step 1 of passwordless sign-in (#219): the
  sign-in forms carry `action`/`method` fallbacks, so a visitor whose
  network blocks the WebSocket handshake — or whose browser runs no
  JavaScript — can request a code without ever reaching the LiveView.

  The endpoint is a thin transport shim: `Identity.request_auth_code/1`
  keeps every guarantee (format validation, the 60-second send throttle,
  the AccessRule gate, the delivery failure burn) and `AuthFlow` keeps
  the copy identical to the connected flow. On success the address rides
  the session — never a URL — to the code page, so the verify step can
  re-render without exposing the address in history, referrers, or logs.

  The verify step has no controller of its own: its form still POSTs to
  `SessionController`, which accepts the code where the connected flow
  accepts its minted token (the same session-write seam, #219).
  """

  use FluxValeWeb, :controller

  alias FluxVale.Identity
  alias FluxValeWeb.AuthFlow
  alias FluxValeWeb.ReturnPath

  @doc """
  Requests a sign-in code and lands on the code step. Failures flash the
  shared copy and return to the email form with the same `return_to`, so
  a retry never forgets the destination.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    email = Map.get(params, "email", "")
    return_to = ReturnPath.safe(params["return_to"])
    outcome = Identity.request_auth_code(email)

    case AuthFlow.request_outcome(outcome) do
      {:ok, message} ->
        conn
        |> put_session("sign_in_email", to_string(email))
        |> put_flash(:info, message)
        |> redirect(to: ReturnPath.code_path(return_to))

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ReturnPath.sign_in_path(return_to))
    end
  end
end

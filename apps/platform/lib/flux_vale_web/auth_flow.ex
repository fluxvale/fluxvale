defmodule FluxValeWeb.AuthFlow do
  @moduledoc """
  The sign-in flow's UX contract (#219): one mapping from an
  `FluxVale.Identity` passwordless operation's result to the flash copy
  and the next step.

  Two transports read it — the LiveView (the connected experience) and
  the native POST fallback (`SignInController` / `SessionController`,
  the resilience track for networks that block the WebSocket handshake)
  — so a copy or step change can never fork between them. The
  operations own the guarantees (throttle, expiry, attempt cap, the
  AccessRule gate, the signup telemetry); this module owns only what
  the visitor sees.

  Step 1 (`request_outcome/1`) either advances to the code step or
  stays on the email step. Step 2 (`verify_outcome/1`) returns the
  minted token, a retry on the code step, or a terminal refusal back on
  the email step.
  """

  @typedoc "`FluxVale.Identity.request_auth_code/2`'s result"
  @type request_result :: :ok | {:error, atom()}

  @typedoc "`FluxVale.Identity.verify_auth_code/2`'s result"
  @type verify_result :: {:ok, map(), String.t()} | {:error, atom()}

  @doc """
  The code request's answer: `{:ok, copy}` advances the form to the code
  step, `{:error, copy}` keeps the email step and names the reason.
  """
  @spec request_outcome(request_result()) :: {:ok, String.t()} | {:error, String.t()}
  def request_outcome(:ok) do
    {:ok, "Code sent. Check your inbox."}
  end

  def request_outcome({:error, :throttled}) do
    {:error, "Please wait a minute before requesting another code."}
  end

  # #26: explicit, not enumeration-safe — staging is team-only;
  # uniform messaging is a beta-invite-flow concern, not an M2 one
  def request_outcome({:error, :not_allowed}) do
    {:error, "That address can't sign in yet. Ask an admin for access."}
  end

  def request_outcome({:error, :delivery_failed}) do
    {:error, "We couldn't send the email. Please wait a minute, then try again."}
  end

  def request_outcome({:error, :invalid_address}) do
    {:error, "That doesn't look like an email address. Check it and try again."}
  end

  @doc """
  The code verify's answer: `{:ok, user, token}` is the session mint (the
  LiveView hands the token to `SessionController` in a POST body; the
  native path stores it in one hop), `{:code, copy}` stays on the code
  step for a retry, `{:email, copy}` returns to the email step — the
  terminal refusals where the sent code can never succeed.
  """
  @spec verify_outcome(verify_result()) ::
          {:ok, map(), String.t()} | {:code, String.t()} | {:email, String.t()}
  def verify_outcome({:ok, user, token}) do
    {:ok, user, token}
  end

  def verify_outcome({:error, :locked_out}) do
    {:email, "Too many attempts. Request a fresh code."}
  end

  # #26: the rule changed after the code was sent — retrying that code
  # can never succeed; back to the email step with the why
  def verify_outcome({:error, :not_allowed}) do
    {:email, "That address can't sign in yet. Ask an admin for access."}
  end

  # #478/#502: the invitation wall — the friction point's honest copy,
  # no dead end (the ask sits in the text). The login code burned with
  # the verify, so the retry is a fresh request anyway.
  def verify_outcome({:error, :invitation_required}) do
    {:email,
     "FluxVale is in invitation-only early access. Creating an account needs an " <>
       "invited address. Write to support@fluxvale.com and we'll send you an invite."}
  end

  # #502: the invited account's only door is the emailed accept link — a
  # code verify can never open it.
  def verify_outcome({:error, :invite_pending}) do
    {:email,
     "This address has an invitation waiting. Use the link in the invitation email " <>
       "to accept it."}
  end

  # Uniform message: unknown address and wrong code look identical
  def verify_outcome({:error, _reason}) do
    {:code, "That code didn't match. Try again."}
  end
end

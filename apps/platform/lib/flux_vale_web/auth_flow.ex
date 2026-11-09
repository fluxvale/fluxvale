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
  the email step. The Google arm (#642) adds `google_outcome/1` (the
  operation's result map — every refusal lands on the email step;
  there is no code step to retry) and the door-shut/throttle copy its
  hops share with the button's render predicate.
  """

  # #642: shared with the email arm's strings verbatim — one home per
  # copy, two arms referencing it (the operation atoms map onto the
  # same visitor-facing reasons). The Google-only strings live here
  # too, so the "one home" claim covers the whole arm.
  @copy_not_allowed "That address can't sign in yet. Ask an admin for access."

  @copy_invitation_required "FluxVale is in invitation-only early access. Creating an account needs an " <>
                              "invited address. Write to support@fluxvale.com and we'll send you an invite."

  @copy_invite_pending "This address has an invitation waiting. Use the link in the invitation email " <>
                         "to accept it."

  @copy_google_unverified "Your Google account's email isn't verified by Google. Verify it there, then try again, or use an email code."

  @copy_google_residual "Google sign-in didn't work. Please try again, or use an email code."

  @copy_google_unavailable "Google sign-in isn't available here. Use an email code."

  @copy_google_throttled "Please wait a minute before trying again."

  @typedoc "`FluxVale.Identity.request_auth_code/2`'s result"
  @type request_result :: :ok | {:error, atom()}

  @typedoc "`FluxVale.Identity.verify_auth_code/2`'s result"
  @type verify_result :: {:ok, map(), String.t()} | {:error, atom()}

  @typedoc "`FluxVale.Identity.sign_in_with_google/1`'s result (#642)"
  @type google_result :: {:ok, map(), String.t()} | {:error, atom()}

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
    {:error, @copy_not_allowed}
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
    {:email, @copy_not_allowed}
  end

  # #478/#502: the invitation wall — the friction point's honest copy,
  # no dead end (the ask sits in the text). The login code burned with
  # the verify, so the retry is a fresh request anyway.
  def verify_outcome({:error, :invitation_required}) do
    {:email, @copy_invitation_required}
  end

  # #502: the invited account's only door is the emailed accept link — a
  # code verify can never open it.
  def verify_outcome({:error, :invite_pending}) do
    {:email, @copy_invite_pending}
  end

  # Uniform message: unknown address and wrong code look identical
  def verify_outcome({:error, _reason}) do
    {:code, "That code didn't match. Try again."}
  end

  @doc """
  The Google arm's answer (#642): `{:ok, user, token}` is the session
  mint (the controller writes it in one server-side hop), `{:error,
  copy}` lands on `/sign-in` — every refusal is terminal for the
  Google flow, so the arm returns one error shape. The shared reasons
  (`:not_allowed`, `:invitation_required`, `:invite_pending`) reuse
  the email arm's strings verbatim; `:email_not_verified` and the
  VerifyAuthCode residuals (`:address_unresolved`, `:user_lookup_failed`,
  `:provisioning_failed`) get Google-appropriate copy that always
  names the email-code alternative (plan §5).
  """
  @spec google_outcome(google_result()) :: {:ok, map(), String.t()} | {:error, String.t()}
  def google_outcome({:ok, user, token}) do
    {:ok, user, token}
  end

  def google_outcome({:error, :not_allowed}) do
    {:error, @copy_not_allowed}
  end

  def google_outcome({:error, :invitation_required}) do
    {:error, @copy_invitation_required}
  end

  def google_outcome({:error, :invite_pending}) do
    {:error, @copy_invite_pending}
  end

  # Plan §4's edge row: Google has not verified the account's address
  # — the strict gate refused it before any lookup; the fix lives in
  # the visitor's Google account, and the email door stays open.
  def google_outcome({:error, :email_not_verified}) do
    {:error, @copy_google_unverified}
  end

  # The residuals mirror VerifyAuthCode (plan §3.3): a retryable
  # post-supersede race window and DB-read arms the visitor cannot
  # act on beyond retrying — the honest register the email arm uses.
  def google_outcome({:error, _residual}) do
    {:error, @copy_google_residual}
  end

  @doc """
  The Google arm's door-shut copy (#642, D-flag): flag off or
  credentials absent — the same predicate the button renders under,
  so the hop and the button can never disagree on what "unavailable"
  says. Names the email alternative (plan §5: it is always on).
  """
  @spec google_unavailable() :: String.t()
  def google_unavailable do
    @copy_google_unavailable
  end

  @doc """
  The Google arm's throttle copy (#642, D-abuse): the same "wait a
  minute" register the email arm's send throttle uses.
  """
  @spec google_throttled() :: String.t()
  def google_throttled do
    @copy_google_throttled
  end
end

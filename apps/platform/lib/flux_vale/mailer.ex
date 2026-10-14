defmodule FluxVale.Mailer do
  @moduledoc """
  Swoosh mailer + the recipient split at the mailer seam (ADR-0003 Am. 2):
  test-account mail captures in-app via `Swoosh.Adapters.Local` (the gated
  TestInbox #22 is the only sanctioned viewer); every other recipient
  delivers through the configured adapter (Local in dev, Postmark on
  staging/review). A few lines here — not per-environment config forks —
  decide capture vs. delivery.
  """

  use Swoosh.Mailer, otp_app: :flux_vale

  alias FluxVale.TestInbox
  alias Swoosh.Adapters.Local

  @doc """
  The passwordless sign-in code (ADR-0003): plain body, just the code —
  transactional minimalism for deliverability.
  """
  @spec deliver_auth_code(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def deliver_auth_code(to, code) do
    %Swoosh.Email{}
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
    |> Swoosh.Email.subject("Your FluxVale sign-in code")
    |> Swoosh.Email.text_body("Your sign-in code is #{code}. It expires in 10 minutes.")
    |> deliver()
  end

  @doc """
  #124's low-runway warning (one per episode — the sweep's marker owns
  the once): plain body, the number that matters, where to act. A
  non-positive `runway_hours` means the balance already ran out — the
  copy swaps to the overdrawn sentence instead of "about -3 hours".
  """
  @spec deliver_low_balance_warning(String.t(), integer()) :: {:ok, map()} | {:error, term()}
  def deliver_low_balance_warning(to, runway_hours) do
    coverage =
      if runway_hours > 0 do
        "Your FluxVale balance covers about #{runway_hours} hours at current usage."
      else
        "Your FluxVale balance has run out at current usage."
      end

    %Swoosh.Email{}
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
    |> Swoosh.Email.subject("Your FluxVale balance is running low")
    |> Swoosh.Email.text_body("""
    #{coverage}

    Add credits from the Billing page to keep your instances running. At zero, running instances stop automatically — your data stays, and they start again once the balance is positive.
    """)
    |> deliver()
  end

  @doc """
  #124's destroy-window warnings (T-7, then T-1): the data-deletion
  commitment in user-facing words (docs/data-deletion.md).
  """
  @spec deliver_destroy_warning(String.t(), Date.t(), 7 | 1) ::
          {:ok, map()} | {:error, term()}
  def deliver_destroy_warning(to, destroy_on, days_left) do
    date = Calendar.strftime(destroy_on, "%B %d, %Y")

    %Swoosh.Email{}
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
    |> Swoosh.Email.subject(
      "Your FluxVale instances will be deleted in #{days_left} #{if(days_left == 1, do: "day", else: "days")}"
    )
    |> Swoosh.Email.text_body("""
    Your wallet balance has been negative with your instances stopped, and the redemption window is closing.

    On #{date} the stopped instances — and the data they store — will be deleted for good. Top up the wallet before then to keep them; they start again as soon as the balance is positive.
    """)
    |> deliver()
  end

  # The recipient split (ADR-0003 Am. 2). Overriding the mailer macro's
  # deliver keeps the decision at one seam every caller already crosses;
  # `super/2` preserves the macro's telemetry for the delivered path. The
  # capture path deliberately skips it — nothing left the BEAM, there is
  # no delivery event to instrument.
  @doc """
  Delivers per the configured adapter, or captures into the TestInbox
  storage when `FluxVale.TestInbox.capture?/1` says the mail belongs
  there.
  """
  @spec deliver(Swoosh.Email.t(), Keyword.t()) :: {:ok, term()} | {:error, term()}
  def deliver(email, config \\ [])

  def deliver(email, config) do
    if TestInbox.capture?(email) do
      Local.deliver(email, storage_driver: TestInbox.storage_driver())
    else
      super(email, config)
    end
  end
end

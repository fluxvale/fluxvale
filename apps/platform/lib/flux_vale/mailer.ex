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

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

  alias FluxVale.Pricing
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

    Add credits from the Billing page to keep your instances running. At zero, running instances stop automatically. Your data stays, and they start again once the balance is positive.
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

    On #{date} the stopped instances, and the data they store, will be deleted for good. Top up the wallet before then to keep them. They start again as soon as the balance is positive.
    """)
    |> deliver()
  end

  @doc """
  The top-up payment outcome (#377): the durable email twin of the
  in-app result state (#391) — amount credited plus the resulting
  balance. Polar is the Merchant of Record and sends the legal
  receipt, so this never duplicates it: one plain pointer line, no
  receipt generation or link (Polar has no stable per-order receipt
  URL — only short-lived presigned PDFs and portal-gated downloads).
  """
  @spec deliver_topup_completed(String.t(), integer(), integer()) ::
          {:ok, map()} | {:error, term()}
  def deliver_topup_completed(to, amount_cents, balance_cents) do
    amount = Pricing.format_usd(amount_cents)
    balance = Pricing.format_usd(balance_cents)

    %Swoosh.Email{}
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
    |> Swoosh.Email.subject("Your FluxVale payment went through")
    |> Swoosh.Email.text_body("""
    We received your payment of #{amount}. Your credit was added and your balance is now #{balance}.

    Your receipt arrives from Polar in a separate email.
    """)
    |> deliver()
  end

  @doc """
  The not-completed outcome (#377): what happened in plain words,
  the no-charge fact, and the retry link (the top-up start path).
  Only genuinely terminal outcomes mail — pending is not an outcome,
  the webhook may still be in flight.
  """
  @spec deliver_topup_not_completed(String.t(), :failed | :expired) ::
          {:ok, map()} | {:error, term()}
  def deliver_topup_not_completed(to, outcome) do
    {subject, what} = not_completed_copy(outcome)

    %Swoosh.Email{}
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.text_body("""
    #{what} You were not charged.

    You can try again at #{topup_url()}.
    """)
    |> deliver()
  end

  defp not_completed_copy(:failed) do
    {"Your FluxVale payment didn't go through", "Your top-up didn't go through."}
  end

  defp not_completed_copy(:expired) do
    {"Your FluxVale top-up expired", "Your top-up expired without being completed."}
  end

  @doc """
  The post author's status notification (fluxvale/fluxvale#412 T7): the
  board moves their post and the author hears it from us first. Plain
  body, the status phrase and the title, where to follow it — the same
  transactional minimalism as the other mails. One mail per fresh
  transition; the set_status trigger (`Feedback.Post.AuthorStatusMail`)
  owns the once.
  """
  @spec deliver_feedback_status_changed(String.t(), atom(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def deliver_feedback_status_changed(to, status, title, slug) do
    phrase = status_phrase(status)

    %Swoosh.Email{}
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
    |> Swoosh.Email.subject("Your FluxVale feedback post #{phrase}")
    |> Swoosh.Email.text_body("""
    Your feedback post "#{title}" #{phrase}.

    You can follow it at #{feedback_post_url(slug)}.
    """)
    |> deliver()
  end

  # The status reads as prose, not an atom dump — the same copy-pair
  # shape as not_completed_copy above. One clause per declared status
  # (Post's one_of constraint is the front door): a new status must land
  # here with its words, and the missing clause fails loudly rather than
  # mailing broken English.
  defp status_phrase(:open), do: "is open again"
  defp status_phrase(:planned), do: "is now planned"
  defp status_phrase(:started), do: "is now started"
  defp status_phrase(:completed), do: "is now complete"
  defp status_phrase(:duplicate), do: "was marked as a duplicate"
  defp status_phrase(:declined), do: "has been declined"

  # Emails carry the canonical origin (the prod URL is the truth
  # regardless of the sending host, the same stance as the SEO seam).
  defp topup_url do
    origin = Application.get_env(:flux_vale, :canonical_origin, "https://fluxvale.com")
    origin <> "/billing/topup"
  end

  # ADR-0026 §4 pins /feedback/:slug as the post page's shape.
  defp feedback_post_url(slug) do
    origin = Application.get_env(:flux_vale, :canonical_origin, "https://fluxvale.com")
    origin <> "/feedback/" <> slug
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

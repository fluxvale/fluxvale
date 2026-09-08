defmodule FluxVale.TestInbox do
  @moduledoc """
  The gated TestInbox (#22): non-prod mail capture over
  `Swoosh.Adapters.Local` storage — config-gated and admin-auth'd because a
  public mailbox viewer is an account-takeover machine (ADR-0023 Am. 3; it
  displays live login codes).

  Two concerns meet here:

  - **Who gets captured** — the recipient split at the mailer seam
    (ADR-0003 Am. 2): on staging/review, only test accounts
    (`test@fluxvale.com` and its plus-addresses) capture via Local;
    everyone else delivers through the configured adapter. `capture?/1` is
    the predicate `FluxVale.Mailer` consults. Capture requires *all*
    recipients to be test accounts — a mixed mail always delivers, so a
    human's copy is never silently swallowed by the inbox.
  - **What the inbox serves** — `list_mails/1` and `latest_mail/1` over the
    storage driver, in a stable JSON-ready shape for the future E2E
    adapters (ADR-0024 Am. 1: a first-party endpoint, not scraped Swoosh
    markup).

  Config namespace `:test_inbox` (`enabled:`, `storage_driver:`) is read at
  call time on purpose: `storage_driver` is the pre-decided M4 seam
  (ADR-0023 Am. 3) — swap Memory for the DB-backed dev adapter and this
  module, the endpoint, and every test stay untouched.

  NB: on prod, `config :swoosh, :local: false` means the Memory driver's
  process isn't even started — capture is structurally dead there, on top
  of `enabled: false`.
  """

  alias Swoosh.Adapters.Local.Storage.Memory

  @test_account_domain "fluxvale.com"
  @test_account_local "test"

  # The sign-in code (6 digits, ADR-0003) — first standalone match in the
  # text body. Best-effort convenience for E2E polling, nil when absent:
  # adapters must not treat `code` as present for arbitrary mail.
  @code_pattern ~r/\b\d{6}\b/

  @doc """
  Is the TestInbox surface enabled? Runtime config (`:test_inbox,
  enabled:`) — the web gate 404s when false, which is how the routes are
  "absent under prod config" while staging can flip the same release
  (ADR-0010's same-image rule; see runtime.exs).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config()[:enabled] == true
  end

  @doc """
  The storage driver behind capture and serving — the M4 swap seam
  (ADR-0023 Am. 3: Memory → a DB-backed dev adapter; same endpoint, no
  test changes). Read per-call so a release can re-point at boot.
  """
  @spec storage_driver() :: module()
  def storage_driver do
    config()[:storage_driver] || Memory
  end

  @doc """
  Should this mail be captured instead of delivered? The mailer-seam half
  of the recipient split (ADR-0003 Am. 2): true when the TestInbox is
  enabled and **every** recipient — to, cc, and bcc alike — is a test
  account (`test@fluxvale.com`, plus-addressed variants included). Any
  human anywhere in the recipient list means the mail delivers.
  """
  @spec capture?(Swoosh.Email.t()) :: boolean()
  def capture?(%Swoosh.Email{to: to, cc: cc, bcc: bcc}) do
    recipients = to ++ cc ++ bcc
    addresses = Enum.map(recipients, &recipient_address/1)

    enabled?() and addresses != [] and Enum.all?(addresses, &test_account?/1)
  end

  @doc """
  All captured mails, newest first (Memory prepends on push), optionally
  filtered to one recipient address.
  """
  @spec list_mails(String.t() | nil) :: [map()]
  def list_mails(address \\ nil) do
    emails = storage_driver().all()
    mails = Enum.map(emails, &to_mail/1)

    case address do
      nil ->
        mails

      address ->
        wanted = String.downcase(address)
        Enum.filter(mails, fn mail -> wanted in Enum.map(mail.to, &String.downcase/1) end)
    end
  end

  @doc """
  The newest captured mail for `address` — the E2E polling shape: poll
  until `{:ok, mail}`, read `mail.code`. `{:error, :not_found}` until the
  code-send lands (or when the address never captured).
  """
  @spec latest_mail(String.t()) :: {:ok, map()} | {:error, :not_found}
  def latest_mail(address) when is_binary(address) do
    emails = storage_driver().all()

    case Enum.find(emails, &delivered_to?(&1, address)) do
      nil -> {:error, :not_found}
      email -> {:ok, to_mail(email)}
    end
  end

  # -- capture pattern ----------------------------------------------------

  # `test@fluxvale.com` and `test+<anything>@fluxvale.com` (ADR-0023's seed
  # account; plus-addressing gives E2E runs private, deterministic
  # mailboxes without new seeds). Case-insensitive per RFC 5321.
  defp test_account?(address) do
    downcased = String.downcase(address)

    case String.split(downcased, "@") do
      [local, @test_account_domain] ->
        local == @test_account_local or String.starts_with?(local, @test_account_local <> "+")

      _other ->
        false
    end
  end

  defp recipient_address({_name, address}), do: address
  defp recipient_address(address) when is_binary(address), do: address

  # -- serving ------------------------------------------------------------

  defp delivered_to?(%Swoosh.Email{} = email, address) do
    wanted = String.downcase(address)

    Enum.any?(email.to, fn recipient ->
      address = recipient_address(recipient)
      String.downcase(address) == wanted
    end)
  end

  # The stable JSON shape — the contract ADR-0024's E2E adapters ride.
  # Keep additive-only: fields never renamed or dropped.
  defp to_mail(%Swoosh.Email{} = email) do
    %{
      id: email.headers["Message-ID"],
      from: recipient_address(email.from),
      to: Enum.map(email.to, &recipient_address/1),
      subject: email.subject,
      text_body: email.text_body,
      html_body: email.html_body,
      code: extract_code(email.text_body),
      sent_at: email.private[:sent_at]
    }
  end

  defp extract_code(nil), do: nil

  defp extract_code(text_body) do
    case Regex.run(@code_pattern, text_body) do
      [code] -> code
      nil -> nil
    end
  end

  defp config do
    Application.get_env(:flux_vale, :test_inbox, [])
  end
end

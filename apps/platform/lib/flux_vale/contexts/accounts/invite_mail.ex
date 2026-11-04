defmodule FluxVale.Accounts.InviteMail do
  @moduledoc """
  The invitation mail (slice 4 of #408) — the notify layer
  InviteMember calls: resolves what the mail needs (the org's name, the
  canonical accept link carrying the RAW token) and hands the words to
  `Mailer.deliver_org_invitation/3`.

  The raw token exists in exactly two places: this call site's frame and
  the emailed link. Delivery failure logs and never fails the invite
  (the TopupOutcomeMail discipline): the row is the truth, the owner
  sees it pending and can revoke and resend.
  """

  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Mailer

  require Logger

  @doc """
  Mails the invitation for a freshly created row. Returns :ok either
  way — a mail failure is the owner's resend, not an error.
  """
  @spec deliver(MembershipInvite.t(), String.t()) :: :ok
  def deliver(%MembershipInvite{} = invite, raw_token) when is_binary(raw_token) do
    # The org name rides an authorize-free load (the AuthorUsername
    # posture — notifying is the mailer's job, not an authorization
    # question).
    case Ash.load(invite, :organization, authorize?: false) do
      {:ok, %{organization: org}} ->
        deliver_mail(org.name, invite, raw_token)

      # coveralls-ignore-start - defensive: a DB read failure mid-hook,
      # not simulatable under the sandbox (DBConnection reconnects —
      # the repo's cluster-level stance)
      {:error, reason} ->
        log_failure(invite, reason)

        # coveralls-ignore-stop
    end
  end

  defp deliver_mail(org_name, invite, raw_token) do
    address = to_string(invite.email)

    case Mailer.deliver_org_invitation(address, org_name, accept_url(raw_token)) do
      {:ok, _delivery} -> :ok
      {:error, reason} -> log_failure(invite, reason)
    end
  end

  defp log_failure(invite, reason) do
    Logger.error("Invite mail failed for #{invite.id}: #{inspect(reason)}")
    :ok
  end

  # Emails carry the canonical origin (the prod URL is the truth
  # regardless of the sending host — the Mailer topup_url stance).
  defp accept_url(raw_token) do
    origin = Application.get_env(:flux_vale, :canonical_origin, "https://fluxvale.com")
    origin <> "/invitations/accept?token=" <> raw_token
  end
end

defmodule FluxVale.Ops.InvitedEmail.DeliverInvitation do
  @moduledoc """
  Sends the informational invitation email after the row commits
  (#478) — after_action, so a delivered email always means a recorded
  invite. The email carries no token and no link credential: the gate
  is the row, the email is the courtesy ("you are on the list").

  Best-effort by design: a delivery failure logs a warning and does NOT
  fail the create — the row admits the address either way, and the
  operator can always resend by re-running the invite (the unique
  address would refuse; remove the row and re-add). Revisit trigger: if
  silent email failures ever matter, surface them as a pending-send
  column and a janitor sweep — deliberately not built now.
  """

  use Ash.Resource.Change

  alias FluxVale.Mailer

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, invited ->
      address = to_string(invited.address)

      case Mailer.deliver_invitation(address) do
        {:ok, _receipt} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "invitation email for #{address} failed to deliver (#{inspect(reason)}) — " <>
              "the invite is recorded; the address can sign in regardless"
          )
      end

      {:ok, invited}
    end)
  end
end

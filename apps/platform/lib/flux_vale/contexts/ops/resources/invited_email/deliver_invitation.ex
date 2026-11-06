defmodule FluxVale.Ops.InvitedEmail.DeliverInvitation do
  @moduledoc """
  Sends the informational invitation email once the invitation row is
  durable (#478): an after_transaction hook (success-only), so a sent
  email always means a committed row, and no email rides a create that
  failed. The email carries no token and no link credential: the gate
  is the row, the email is the courtesy ("you are on the list").

  Best-effort by design: a delivery failure in any shape (an
  {:error, _} result, an exit, a raise, a throw) logs a warning and does
  NOT fail the create — the row admits the address either way, and the
  operator resends by removing the row and re-adding (the :destroy
  lever exists for exactly that).
  """

  use Ash.Resource.Change

  alias FluxVale.Mailer

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, invited} ->
        deliver_and_log(invited)
        {:ok, invited}

      # no row, no email: the courtesy follows the credential
      _changeset, {:error, _failed} = failure ->
        failure
    end)
  end

  defp deliver_and_log(invited) do
    address = to_string(invited.address)
    outcome = try_delivery(address)
    log_outcome(address, outcome)
  end

  # Contains every failure shape the mailer can produce: an {:error, _}
  # result, a raise, an exit, a throw (unconfigured adapters have been
  # known to exit rather than return).
  defp try_delivery(address) do
    Mailer.deliver_invitation(address)
  rescue
    e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
  catch
    kind, value -> {:error, "#{kind}: #{inspect(value)}"}
  end

  defp log_outcome(_address, {:ok, _receipt}) do
    :ok
  end

  defp log_outcome(address, {:error, reason}) do
    Logger.warning(
      "invitation email for #{address} failed to deliver (#{inspect(reason)}) - " <>
        "the invite is recorded; the address can sign in regardless"
    )
  end
end

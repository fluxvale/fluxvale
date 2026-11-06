defmodule FluxVale.TestSupport.InvitationHelpers do
  @moduledoc false

  # Shared helpers for the invitation gate (#478) — test/support is
  # credo-exempt by config; tests own their preconditions. Invitations
  # ride the resource's :create action (authorize?: false, the seeds
  # posture for operator-precondition rows), so the delivery hook fires
  # exactly as it does for an admin: each invite sends one email to the
  # test process mailbox. `drain_mail!` clears it when the test's next
  # assertion is a DIFFERENT email (the login code).

  alias FluxVale.Ops.InvitedEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  @doc """
  Records an invitation for `address` through the create action and
  returns the row. Sends the invitation email — drain it if a later
  assertion expects a different mail.
  """
  def invite_address!(address) do
    {:ok, invited} =
      InvitedEmail
      |> Ash.Changeset.for_create(:create, %{address: address}, authorize?: false)
      |> Ash.create(authorize?: false)

    invited
  end

  @doc "Revokes through the action (the operator's path), returns the row."
  def revoke!(invited) do
    {:ok, revoked} =
      invited
      |> Ash.Changeset.for_update(:revoke, %{}, authorize?: false)
      |> Ash.update(authorize?: false)

    revoked
  end

  @doc "The invitation row for an address, or nil."
  def invitation(address) do
    InvitedEmail
    |> Ash.Query.filter(address == ^address)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, row} -> row
      {:error, _} -> nil
    end
  end

  @doc "Drops one pending email from the test mailbox, if any."
  def drain_mail! do
    receive do
      {:email, _mail} -> :ok
    after
      0 -> :ok
    end
  end
end

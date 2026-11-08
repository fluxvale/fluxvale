defmodule FluxVale.Identity.User.AcceptInvitedEmailRow do
  @moduledoc """
  Flips the invitation's reservation at :accept_invite (#502, re-homed
  #287): the account's PENDING row goes VERIFIED and PRIMARY —
  acceptance is the inbox proof (the one-time link IS the credential),
  the same end state the JIT path's SignupEmailRow writes at birth.

  Two sanctioned writes, both inside the accept transaction: :mark_verified
  (the only verified_at stamp past the JIT mirror), then :set_primary
  (the sanctioned promotion — an invited account owns no other rows, so
  no sibling demotion ever runs). Rolling the flip's failure back with
  the accept matters: an accepted account without a verified primary
  row could neither sign in (verified-only resolution) nor display
  (every surface reads the primary).

  The pending row is located, never re-derived from an address
  argument: the reservation IS the invitation's address record —
  whatever row exists is the one the link was minted for. A missing
  row is drift (structurally impossible past the re-home: :invite
  writes it, nothing removes it while the invitation is unaccepted —
  RemoveGuard's invitation-address arm) and refuses the accept loudly.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.UserEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case pending_row(user) do
        %UserEmail{} = row ->
          flip(row)
          {:ok, user}

        nil ->
          {:error, :invitation_row_missing}
      end
    end)
  end

  defp pending_row(user) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user.id and is_nil(verified_at))
    |> Ash.read_one!(authorize?: false)
  end

  defp flip(row) do
    # authorize?: false throughout — system seam inside the accept's
    # transaction; the token was the credential (the AcceptInvitation
    # posture).
    {:ok, verified} =
      row
      |> Ash.Changeset.for_update(:mark_verified, %{})
      |> Ash.update(authorize?: false)

    verified
    |> Ash.Changeset.for_update(:set_primary, %{})
    |> Ash.update(authorize?: false)
  end
end

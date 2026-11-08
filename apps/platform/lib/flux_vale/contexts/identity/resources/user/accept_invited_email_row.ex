defmodule FluxVale.Identity.User.AcceptInvitedEmailRow do
  @moduledoc """
  Flips the invitation's reservation at :accept_invite (#502, re-homed
  #287): the account's PENDING row goes VERIFIED and PRIMARY —
  acceptance is the inbox proof (the one-time link IS the credential),
  the same end state the JIT path's SignupEmailRow writes at birth.

  Two sanctioned writes, both inside the accept transaction (an
  {:error, _} from either rolls the whole accept back, stamp included —
  the with in flip/2 propagates): :mark_verified, then :set_primary
  (the sanctioned promotion — an invited account owns no other rows,
  so no sibling demotion ever runs). The rollback matters: an accepted
  account without a verified primary row could neither sign in
  (verified-only resolution) nor display (every surface reads the
  primary).

  The pending row is located, never re-derived from an address
  argument: the reservation IS the invitation's address record —
  whatever row exists is the one the link was minted for. A missing
  row is drift (unproducible past the re-home: :invite writes the
  reservation and the :supersede_pending action itself refuses to
  delete an unaccepted invitation's row) and refuses the accept loudly.
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
          flip(row, user)

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

  # Both halves of the flip must hold, or the whole accept rolls back
  # (an {:error, _} from after_action aborts the update's transaction —
  # including the invite_accepted_at stamp). Propagating the error
  # tuple instead of pattern-matching the {:ok, _} keeps AcceptInvitation's
  # {:error, atom()} contract intact when either write refuses (a DB
  # failure, or a promotion race the index arbitrates).
  defp flip(row, user) do
    with {:ok, verified} <-
           row
           |> Ash.Changeset.for_update(:mark_verified, %{})
           |> Ash.update(authorize?: false),
         {:ok, _primary} <-
           verified
           |> Ash.Changeset.for_update(:set_primary, %{})
           |> Ash.update(authorize?: false) do
      {:ok, user}
    end
  end
end

defmodule FluxVale.Identity.User.InvitedEmailRow do
  @moduledoc """
  Writes the invitation's address reservation at :invite (#502,
  re-homed #287): the invited address — the :email ARGUMENT, there is
  no column anymore — lands as a PENDING `user_emails` row
  (`verified_at` nil, `is_primary` false) on the pre-created account.

  The reservation's window is the INVITATION's, never the claim TTL
  (the #287 ruling, on the issue): it is created at :invite, kept by
  :reinvite, flipped verified+primary by :accept_invite, and RETAINED
  through withdrawal and expiry — retirement kills the link but keeps
  the address reserved (the frozen-mirror posture; a freed address
  would also break re-invite, which has no other address source). The
  claim-expiry sweep and the proof-carried supersede both exclude rows
  of unaccepted-invitation accounts (UserEmail's seam functions), so
  no code path can orphan an invite. First-verified-wins stays for
  every unreserved address; a stranger's claim on a reserved address
  is refused at `unique_address` — honestly, at add time, instead of
  wedging acceptance after a steal.

  System path, one insert: the row rides the `:add` action so address
  validation and the cap hold. authorize?: false — the invite's own
  policy gated the caller (an admin's write, or operator tooling); an
  inert account's reservation raises no actor question.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.UserEmail

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    address = Ash.Changeset.get_argument(changeset, :email)

    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case write_row(user, address) do
        {:ok, _row} ->
          {:ok, user}

        # Rolls the whole invite back — an invitation without its
        # reservation must not exist (occupant resolution rides the
        # row; a rowless invite could never be re-invited nor found).
        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Writes the pending reservation row for `address` — the :invite
  path's own post-insert step. Pending and non-primary by construction
  (a reservation proves nothing; SetPrimary refuses unverified rows
  anyway). authorize?: false — the caller is the invite write's system
  seam.
  """
  @spec write_row(FluxVale.Identity.User.t(), String.t() | Ash.CiString.t()) ::
          {:ok, UserEmail.t()} | {:error, term()}
  def write_row(user, address) do
    UserEmail
    |> Ash.Changeset.for_create(:add, %{address: address, user: %{id: user.id}})
    # force_change_attribute: for_create has already validated, and the
    # plain setter refuses after that point. Pending is the :add
    # action's own default (verified_at nil, is_primary false) — no
    # overrides, stated for the reader.
    |> Ash.create(authorize?: false)
  end
end

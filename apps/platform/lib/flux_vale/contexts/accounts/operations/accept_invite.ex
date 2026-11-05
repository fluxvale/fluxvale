defmodule FluxVale.Accounts.Operations.AcceptInvite do
  @moduledoc """
  The invitee side of the invitation flow (slice 4 of #408): raw token
  + signed-in user → membership. Two fences in order:

  - the token proves the LINK — a SHA-256 lookup of a value only the
    emailed link holds;
  - the verified primary email proves the PERSON — a case-folded match
    against the invite's address. A leaked link under someone else's
    sign-in gets the distinct `:email_mismatch` answer the page renders
    with plain copy ("sign in with the invited address"), never a join.

  The write runs `authorize?: false` (the system token path): both
  fences ran above, and the accept action's own open-gate filter is the
  race arbiter for anything that moves between resolution and write.
  """

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Accounts.Operations.ResolveInvite
  alias FluxVale.Identity.User

  require Ash.Query

  @type refusal ::
          :unknown_token
          | :already_accepted
          | :revoked
          | :expired
          | :email_mismatch
          | :already_member

  @spec call(term(), User.t()) :: {:ok, MembershipInvite.t()} | {:error, refusal() | term()}
  def call(raw_token, %User{} = user) do
    case ResolveInvite.call(raw_token) do
      {:ok, {:open, invite}} -> accept_after_fences(user, invite)
      {:ok, :accepted} -> {:error, :already_accepted}
      {:ok, :revoked} -> {:error, :revoked}
      {:ok, :expired} -> {:error, :expired}
      {:error, :unknown_token} = unknown -> unknown
    end
  end

  defp accept_after_fences(user, invite) do
    with {:ok, primary} <- verified_primary_email(user),
         :ok <- email_fence(primary, invite.email),
         :ok <- not_already_member?(user.id, invite.organization_id) do
      # The invitee's id rides the action's private argument — set by
      # the system, never an accepted input (the MintPat shape).
      invite
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:user_id, user.id)
      |> Ash.Changeset.for_update(:accept, %{}, authorize?: false)
      |> Ash.update()
    end
  end

  # The display email is the identity — a verified primary row is the
  # only thing that proves the signed-in account controls the invited
  # address (User.primary_email's definition). No row, no proof: the
  # mismatch arm answers.
  defp verified_primary_email(user) do
    # authorize?: false — the system token path reads explicitly (the
    # nested aggregate carries the same flag); the calc itself is the
    # identity this fence compares.
    case Ash.load(user, :primary_email, authorize?: false) do
      {:ok, %{primary_email: nil}} ->
        {:error, :email_mismatch}

      {:ok, %{primary_email: email}} ->
        {:ok, email}

      # coveralls-ignore-start - defensive: the actor read failing is a
      # DB outage, not simulatable under the sandbox (DBConnection
      # reconnects — the repo's cluster-level stance)
      {:error, _load_failure} = error ->
        error

        # coveralls-ignore-stop
    end
  end

  # Case-folded compare (the store is CiString, the loaded calc is a
  # plain string).
  #
  # Known stance (noted for the reviewer of record): this fence folds
  # with Elixir's String.downcase (full Unicode fold), while the
  # open-invite index folds with the database's lower() (collation
  # rules). The two disagree on same-letter variant codepoints (the
  # Kelvin sign and the Angstrom sign fold to "k" and "a" here but not
  # in the DB's lower()), so the store can hold two OPEN invites this
  # fence treats as one address. Not exploitable: a claim still needs
  # mail receipt at that exact address, and a mismatch answers
  # :email_mismatch (fail closed) — the divergence costs at most a
  # duplicate invitation, never an unauthorized join.
  defp email_fence(primary_email, invite_email) do
    invited = to_string(invite_email)

    if String.downcase(primary_email) == String.downcase(invited) do
      :ok
    else
      {:error, :email_mismatch}
    end
  end

  # The friendly pre-check (the seam level, like InviteMember's
  # duplicate arm): Membership's unique_user_per_org identity is the
  # race arbiter behind it — a raced join rolls the accept back whole.
  defp not_already_member?(user_id, organization_id) do
    member? =
      Membership
      |> Ash.Query.filter(user_id == ^user_id and organization_id == ^organization_id)
      |> Ash.exists?(authorize?: false)

    if member?, do: {:error, :already_member}, else: :ok
  end
end

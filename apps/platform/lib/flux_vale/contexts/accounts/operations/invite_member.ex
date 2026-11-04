defmodule FluxVale.Accounts.Operations.InviteMember do
  @moduledoc """
  The owner path of the invitation flow (slice 4 of #408): org + email
  → an OPEN invite plus the invitation mail. The invite carries role
  `:member` by the resource's contract — roles are the single enum axis
  on grant-shaped rows (the owner ruling) and this flow writes no owner
  grant.

  The raw token (32 url-safe bytes) exists only in this call frame and
  the emailed link — the row stores its SHA-256
  (`MembershipInvite.token_hash/1`, the MintPat posture). One OPEN
  invite per (org, email): the seam-level pre-check below gives the
  friendly duplicate answer and the partial unique index is the race
  arbiter (the unique_slug posture).

  Mail failure logs and never fails the invite (the TopupOutcomeMail
  discipline): the row is the truth, the owner sees it pending and can
  revoke and resend.
  """

  alias FluxVale.Accounts.InviteMail
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User

  require Ash.Query

  # 32 url-safe bytes — the same entropy MintPat mints (43 chars
  # unpadded base64).
  @token_bytes 32

  @spec call(User.t(), Organization.t(), String.t() | Ash.CiString.t()) ::
          {:ok, MembershipInvite.t()} | {:error, :duplicate_invite | term()}
  def call(%User{} = owner, %Organization{} = org, email) do
    with :ok <- no_open_invite?(owner, org, email) do
      raw = raw_token()

      # The digest rides the action's private argument — set by the
      # system, never an accepted input (the MintPat shape: the code
      # interface's input map cannot carry private arguments).
      changeset =
        MembershipInvite
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:token_hash, MembershipInvite.token_hash(raw))
        |> Ash.Changeset.for_create(:create, %{organization_id: org.id, email: email},
          actor: owner
        )

      case Ash.create(changeset) do
        {:ok, invite} ->
          InviteMail.deliver(invite, raw)
          {:ok, invite}

        # The index arbitrated a race the pre-check could not see.
        {:error, _taken} = error ->
          error
      end
    end
  end

  # Policy-scoped (the owner is an org member): an unreadable invite
  # simply misses here and the create's own policy answers the caller.
  defp no_open_invite?(owner, org, email) do
    open? =
      MembershipInvite
      |> Ash.Query.for_read(:read, %{}, actor: owner)
      |> Ash.Query.filter(
        organization_id == ^org.id and email == ^email and
          is_nil(accepted_at) and is_nil(revoked_at)
      )
      |> Ash.exists?(actor: owner)

    if open?, do: {:error, :duplicate_invite}, else: :ok
  end

  defp raw_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end

defmodule FluxVale.Accounts.Membership.LastOwnerGuard do
  @moduledoc """
  The last-owner invariant (slice 5 of #408): an organization ALWAYS
  keeps at least one owner. The guard rides all three lifecycle
  actions — a `:set_role` demote, a `:remove_member`, a `:leave` — and
  refuses any write that would take the org's last owner out. The guard
  is the count, not the identity: any second owner present lets the
  write through.

  The org row is locked FOR UPDATE inside the write transaction first,
  then the row is re-read and the owner count taken under that lock:
  concurrent lifecycle writes serialize on the org, so the COUNT each
  one reads is the committed truth (the UserEmail.RemoveGuard posture —
  without the lock, two demotes could each see "another owner exists"
  and both land, leaving zero). Scope of that claim: the count only.
  The caller's owner policy runs BEFORE the transaction and is not
  re-verified under the lock, so an owner demoted in the seconds-long
  policy-to-lock window can complete one write their policy had
  already allowed — the guard keeps the invariant regardless. Revisit
  trigger: the first time a stale-owner write matters (audit or
  otherwise).

  The refusal is field-scoped on `:role` — the plain message an API
  caller reads. The domain seam (`Operations.SetMemberRole` and
  siblings) classifies it and owns the flash sentence.
  """

  use Ash.Resource.Change

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization

  require Ash.Query

  @refusal_message "the organization must keep at least one owner"

  @doc "The field-scoped refusal message — what the domain seam classifies on"
  @spec refusal_message() :: String.t()
  def refusal_message, do: @refusal_message

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &guard_last_owner/1)
  end

  defp guard_last_owner(changeset) do
    lock_org(changeset.data.organization_id)

    case Ash.get(Membership, changeset.data.id, authorize?: false) do
      # Concurrent-window only: org teardown deleted the row and
      # committed between the caller's load and the lock this write
      # holds. ExUnit's single sandbox connection cannot interleave
      # that (the RemoveGuard posture for the same shape).
      # coveralls-ignore-start
      {:error, _gone} ->
        gone(changeset)

      # coveralls-ignore-stop

      {:ok, fresh} ->
        refuse_if_last_owner(fresh, changeset)
    end
  end

  defp refuse_if_last_owner(fresh, changeset) do
    if owner_leaving?(fresh, changeset) and not other_owner?(fresh) do
      Ash.Changeset.add_error(changeset, field: :role, message: refusal_message())
    else
      changeset
    end
  end

  # An owner row loses its org owner two ways: the update demotes it
  # (the accepted `:role` cast is the target), either destroy removes
  # it. A promote, or any write touching a row that is not an owner,
  # cannot violate the invariant. The fresh row answers, never the
  # caller's struct (the ActorOwnsPaidOrg stance).
  defp owner_leaving?(fresh, %{action_type: :update} = changeset) do
    fresh.role == :owner and target_role(changeset, fresh) == :member
  end

  defp owner_leaving?(%{role: :owner}, %{action_type: :destroy}), do: true
  defp owner_leaving?(_fresh, _changeset), do: false

  # The set_role action accepts `:role` only, so the cast value is the
  # demote target; an unchanged attribute falls back to the fresh row.
  defp target_role(changeset, fresh) do
    Ash.Changeset.get_attribute(changeset, :role) || fresh.role
  end

  defp other_owner?(fresh) do
    Membership
    |> Ash.Query.filter(
      organization_id == ^fresh.organization_id and role == :owner and id != ^fresh.id
    )
    |> Ash.exists?(authorize?: false)
  end

  defp gone(changeset) do
    # coveralls-ignore-next-line - reachable only in the teardown race
    # window above, not simulatable under the sandbox
    Ash.Changeset.add_error(changeset, field: :role, message: "membership no longer exists")
  end

  # authorize?: false throughout — invariant checks, same stance as
  # RemoveGuard: the action's policy already gated the caller, this is
  # the row-consistency answer.
  defp lock_org(org_id) do
    Organization
    |> Ash.Query.filter(id == ^org_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
  end
end

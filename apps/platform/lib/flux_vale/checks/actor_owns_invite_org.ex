defmodule FluxVale.Checks.ActorOwnsInviteOrg do
  @moduledoc """
  Policy check: the actor holds an `:owner` membership of the
  organization the invite in play points at — the invite/revoke gate
  (slice 4 of #408). The ownership test is `ActorIsOrganizationOwner`'s
  predicate verbatim (the seam other checks resolve against), so the
  notion cannot fork (the ActorOwnsPaidOrg posture). Mere membership is
  not enough: a `:member` reads the roster and its pending invites, but
  granting access is the owner's call.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Checks.ActorIsOrganizationOwner

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor is an owner of the invite's organization"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case {actor, invite_org_id(context.subject)} do
      {%{id: user_id}, {:ok, org_id}} -> ActorIsOrganizationOwner.owner?(user_id, org_id)
      # No actor or unresolvable org: fail closed.
      _absent -> false
    end
  end

  # A create answers the org the write NAMES — argument first, then the
  # attribute (both intake shapes, the ActorOwnsPaidOrg posture).
  defp invite_org_id(%Ash.Changeset{action_type: :create} = changeset) do
    named =
      Ash.Changeset.get_argument(changeset, :organization_id) ||
        Ash.Changeset.get_attribute(changeset, :organization_id)

    if is_nil(named), do: :error, else: {:ok, named}
  end

  # Atomic changesets carry this placeholder — Ash.reload would raise
  # on it, and no org resolves from it: fail closed.
  defp invite_org_id(%Ash.Changeset{data: %Ash.Changeset.OriginalDataNotAvailable{}}),
    do: :error

  # Update/destroy: the ROW's org, freshly read — the in-memory struct
  # is caller-controlled, the gate is not (the ActorOwnsPaidOrg stance).
  defp invite_org_id(%Ash.Changeset{data: data}) do
    case Ash.reload(data, authorize?: false) do
      {:ok, %{organization_id: org_id}} when not is_nil(org_id) -> {:ok, org_id}
      _unresolved -> :error
    end
  end

  defp invite_org_id(_subject), do: :error
end

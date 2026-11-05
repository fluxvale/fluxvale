defmodule FluxVale.Checks.ActorOwnsMembershipOrg do
  @moduledoc """
  Policy check: the actor holds an `:owner` membership of the
  organization the MEMBERSHIP row in play belongs to — the member
  lifecycle gate (slice 5 of #408): setting roles and removing members.
  The ownership test is `ActorIsOrganizationOwner`'s predicate verbatim
  (the seam other checks resolve against), so the notion cannot fork
  (the ActorOwnsInviteOrg posture). Mere membership is not enough: a
  `:member` reads the roster, but granting and revoking standing is the
  owner's call.

  The invite's check does not generalize (its name and its create arm
  answer the invite), so this is its sibling named for the assertion it
  makes. Row-scoped only — every gated action (`:set_role`,
  `:remove_member`) is an update/destroy on an existing row: the org
  resolves from the ROW freshly read — the in-memory struct is
  caller-controlled, the gate is not (the ActorOwnsPaidOrg stance).
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Checks.ActorIsOrganizationOwner

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor is an owner of the membership's organization"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case {actor, membership_org_id(context.subject)} do
      {%{id: user_id}, {:ok, org_id}} -> ActorIsOrganizationOwner.owner?(user_id, org_id)
      # No actor or unresolvable org: fail closed.
      _absent -> false
    end
  end

  # Atomic changesets carry this placeholder — Ash.reload would raise
  # on it, and no org resolves from it: fail closed.
  defp membership_org_id(%Ash.Changeset{data: %Ash.Changeset.OriginalDataNotAvailable{}}),
    do: :error

  # Update/destroy: the ROW's org, freshly read — the in-memory struct
  # is caller-controlled, the gate is not (the ActorOwnsPaidOrg stance).
  defp membership_org_id(%Ash.Changeset{data: data}) do
    case Ash.reload(data, authorize?: false) do
      {:ok, %{organization_id: org_id}} when not is_nil(org_id) -> {:ok, org_id}
      _unresolved -> :error
    end
  end

  defp membership_org_id(_subject), do: :error
end

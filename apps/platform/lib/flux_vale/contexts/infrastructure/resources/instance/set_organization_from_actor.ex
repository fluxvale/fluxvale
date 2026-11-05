defmodule FluxVale.Infrastructure.Instance.SetOrganizationFromActor do
  @moduledoc """
  Resolves the create's org onto `organization_id` — instances are born
  owned by an organization (#119), the billing/entitlement boundary.

  The org is the create's CONTEXT (#408): an `organization_id` argument
  names the target org (the deploy wizard's picker) and that org wins.
  No argument keeps the personal-org default exactly as before (JIT
  signup guarantees every actor one). Naming an org you don't belong to
  is not refused here — the create policy's membership fence
  (`ActorIsOrganizationMember`) answers Forbidden, the same answer as
  any foreign org.

  The personal-org lookup propagates the action's actor/authorize? (the
  creator is a member, so the authorized read passes policy).
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, %{actor: actor} = context) when not is_nil(actor) do
    case Ash.Changeset.get_argument(changeset, :organization_id) do
      nil ->
        personal_org(changeset, context)

      # The caller named the org: set it and let the policy fence plus
      # the FK answer — a member's named org passes, a non-member's (or
      # a nonexistent id, which has no members) is Forbidden.
      org_id ->
        Ash.Changeset.force_change_attribute(changeset, :organization_id, org_id)
    end
  end

  def change(changeset, _opts, _context) do
    # No actor: the `present(:organization_id)` create validation reports
    # it with a field-scoped message instead of an actor-shaped crash here.
    changeset
  end

  defp personal_org(changeset, context) do
    case FluxVale.Accounts.personal_org_for_user(
           context.actor.id,
           actor: context.actor,
           authorize?: Map.get(context, :authorize?, true)
         ) do
      {:ok, org} ->
        Ash.Changeset.force_change_attribute(changeset, :organization_id, org.id)

      :none ->
        # Not producible through actions (the JIT change provisions the
        # org in the same transaction as the user — tests reach this via
        # Ash.seed!) — but a loud field-scoped message beats a bare
        # required-field error if an actor ever lacks an org.
        Ash.Changeset.add_error(changeset, field: :organization_id, message: "is required")

      # coveralls-ignore-start - defensive: DB read failure mid-create,
      # not simulatable under the sandbox
      {:error, _error} ->
        Ash.Changeset.add_error(changeset, field: :organization_id, message: "org lookup failed")

        # coveralls-ignore-stop
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end

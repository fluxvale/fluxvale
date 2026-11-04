defmodule FluxVale.Feedback.Vote.SetCastDefaults do
  @moduledoc """
  A vote spends its org's slot: `organization_id` is the org the write
  NAMES — the `organization_id` argument — or, unnamed, the actor's
  personal org, and `cast_by_user_id` is the actor (attribution for
  moderation, ADR-0026 §1). Mirrors Post.SetActorDefaults: the lookup
  propagates the action's actor/authorize?; no actor and nothing named →
  the `present(:organization_id)` validation answers field-scoped.

  A NAMED org is pinned even without an actor: the row's org must be
  on the changeset so the write gate (`FluxVale.Checks.ActorOwnsPaidOrg`)
  answers Forbidden instead of a required-field error — anonymous gets
  nothing either way.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    actor = Map.get(context, :actor)
    named = Ash.Changeset.get_argument(changeset, :organization_id)

    changeset
    |> resolve_org(named, actor, context)
    |> stamp_caster(actor)
  end

  # The write NAMES its org — the gate (ActorOwnsPaidOrg) answers on
  # exactly this org. Existence is the FK's business (a dangling id
  # cannot be owned, so the gate forbids first anyway).
  defp resolve_org(changeset, org_id, _actor, _context) when not is_nil(org_id) do
    Ash.Changeset.force_change_attribute(changeset, :organization_id, org_id)
  end

  defp resolve_org(changeset, nil, actor, context) when not is_nil(actor) do
    case FluxVale.Accounts.personal_org_for_user(
           actor.id,
           actor: actor,
           authorize?: Map.get(context, :authorize?, true)
         ) do
      {:ok, org} ->
        Ash.Changeset.force_change_attribute(changeset, :organization_id, org.id)

      :none ->
        # Not producible through actions (signup JIT provisions the org
        # in the same transaction as the user — tests reach this via
        # Ash.seed!); a loud field-scoped message beats a bare
        # required-field error if an actor ever lacks an org.
        Ash.Changeset.add_error(changeset, field: :organization_id, message: "is required")

      # coveralls-ignore-start - defensive: DB read failure mid-create,
      # not simulatable under the sandbox
      {:error, _error} ->
        Ash.Changeset.add_error(changeset, field: :organization_id, message: "org lookup failed")

        # coveralls-ignore-stop
    end
  end

  # No actor and nothing named: the `present(:organization_id)` create
  # validation reports it with a field-scoped message.
  defp resolve_org(changeset, nil, _actor, _context), do: changeset

  defp stamp_caster(changeset, nil), do: changeset

  defp stamp_caster(changeset, actor),
    do: Ash.Changeset.force_change_attribute(changeset, :cast_by_user_id, actor.id)

  @impl Ash.Resource.Change
  def atomic?, do: false
end

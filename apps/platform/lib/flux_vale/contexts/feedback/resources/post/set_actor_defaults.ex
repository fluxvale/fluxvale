defmodule FluxVale.Feedback.Post.SetActorDefaults do
  @moduledoc """
  Posts are born of the actor: `created_by_user_id` is the actor and
  `organization_id` is the org the write NAMES — the `organization_id`
  argument, the paying gate's subject — or, unnamed, the actor's
  personal org (ADR-0026 §2; the gate reads the org via
  `FluxVale.Checks.ActorOwnsPaidOrg`, which resolves it the same way).
  Mirrors Instance.SetOrganizationFromActor: the lookup propagates the
  action's actor/authorize? (a platform admin owns their personal org,
  so the authorized read passes policy); no actor and nothing named →
  the `present(:organization_id)` validation answers with a field-scoped
  message, never a bare Forbidden.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, %{actor: actor} = context) when not is_nil(actor) do
    named = Ash.Changeset.get_argument(changeset, :organization_id)

    changeset
    |> Ash.Changeset.force_change_attribute(:created_by_user_id, actor.id)
    |> resolve_org(named, actor, context)
  end

  def change(changeset, _opts, _context) do
    # No actor: the `present(:organization_id)` create validation reports
    # it with a field-scoped message instead of an actor-shaped crash here.
    changeset
  end

  # The write NAMES its org — the gate (ActorOwnsPaidOrg) answers on
  # exactly this org. Existence is the FK's business (a dangling id
  # cannot be owned, so the gate forbids first anyway).
  defp resolve_org(changeset, org_id, _actor, _context) when not is_nil(org_id) do
    Ash.Changeset.force_change_attribute(changeset, :organization_id, org_id)
  end

  defp resolve_org(changeset, nil, actor, context) do
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

  @impl Ash.Resource.Change
  def atomic?, do: false
end

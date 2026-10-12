defmodule FluxVale.Infrastructure.Instance.SetOrganizationFromActor do
  @moduledoc """
  Resolves the action's actor's org and sets `organization_id` on create —
  instances are born owned by the actor's organization (#119), the
  billing/entitlement boundary. JIT signup guarantees every actor one.

  The lookup propagates the action's actor/authorize? (the creator is a
  member, so the authorized read passes policy).
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, %{actor: actor} = context) when not is_nil(actor) do
    case FluxVale.Accounts.personal_org_for_user(
           actor.id,
           actor: actor,
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

  def change(changeset, _opts, _context) do
    # No actor: the `present(:organization_id)` create validation reports
    # it with a field-scoped message instead of an actor-shaped crash here.
    changeset
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end

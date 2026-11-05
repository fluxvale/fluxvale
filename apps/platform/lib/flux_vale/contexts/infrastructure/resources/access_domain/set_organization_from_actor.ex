defmodule FluxVale.Infrastructure.AccessDomain.SetOrganizationFromActor do
  @moduledoc """
  Resolves the registering actor's org onto the row — AccessDomain's
  own tenancy change. Deliberately NOT a reuse of the Instance module
  of the same name: a change owned by one resource must not define
  another resource's tenancy (that reuse made Instance's private rule
  read as shared infrastructure). Same logic, owned here: the row is
  born in the actor's org — the billing/entitlement boundary (#119's
  stance) — and a member can never mint a row into another org.

  The lookup propagates the action's actor/authorize? (the registrant
  is a member, so the authorized read passes policy).
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
    # No actor: the organization_id is allow_nil?(false), so the insert
    # reports it — the register action is member-facing and always has
    # an actor.
    changeset
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end

defmodule FluxVale.Infrastructure.AccessGateway.SetOrganizationFromActor do
  @moduledoc """
  Resolves the enable create's org onto the row — AccessGateway's own
  tenancy change. Deliberately NOT a reuse of the Instance module of the
  same name (the AccessDomain stance: a change owned by one resource
  must not define another resource's tenancy).

  The org is the create's CONTEXT (#408): the `organization_id` argument
  — the compat input the actor path used to ignore (#360) — now names
  the target org (the access panel's page org), and that org wins. No
  argument keeps the personal-org default. The gates
  (`ActorOrgWalletFunded`, `ActorOrgHasPaid`) read the same resolution,
  so enablement always bills the org whose row is being born. Naming an
  org you don't belong to is refused by the create policy's membership
  fence (`ActorIsOrganizationMember`), not here.

  The actorless system path (the fixtures' `authorize?: false` shape,
  #360) still rides the argument: it copies it onto the attribute — no
  policy runs to fence it, the FK is the only check.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, %{actor: actor} = context) when not is_nil(actor) do
    case Ash.Changeset.get_argument(changeset, :organization_id) do
      nil ->
        personal_org(changeset, context)

      # The caller named the org: set it and let the policy fence plus
      # the FK answer (the Instance module's stance — same semantics,
      # owned here).
      org_id ->
        Ash.Changeset.force_change_attribute(changeset, :organization_id, org_id)
    end
  end

  def change(changeset, _opts, _context) do
    # No actor (the system seam): the compat argument names the org.
    Ash.Changeset.force_change_attribute(
      changeset,
      :organization_id,
      Ash.Changeset.get_argument(changeset, :organization_id)
    )
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

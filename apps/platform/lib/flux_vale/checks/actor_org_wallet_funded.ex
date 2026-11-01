defmodule FluxVale.Checks.ActorOrgWalletFunded do
  @moduledoc """
  Policy check: the org in play has a wallet balance > 0 — #124's
  deploy gate. Policy-land, not UI-land, so the API can't walk around
  it; wired to Instance `create` (new deploys) and `start` (resuming
  spends too — create-while-positive, stop, start-at-zero would
  otherwise route around the gate).

  The org in play resolves by action shape — create vs update comes from
  the changeset's action type, never from a nil attribute (a forged
  `organization_id: nil` on an update must not reroute the gate to the
  caller's own wallet). Creates that NAME their instance
  (`BackupSetting`) resolve the org from THAT instance — the row's org
  — freshly read and fail-closed; creates without one (the gateway —
  `SetOrganizationFromActor` pins the actor's org moments later)
  resolve the actor's personal org. Updates re-read the ROW from the
  database: an in-process caller controls the changeset's in-memory
  struct, and the gate must not be caller-controlled. The row's org
  rides `organization_id` directly, or THROUGH the row's instance (a
  `BackupSetting` belongs to its instance, not the organization); a row
  whose org cannot be resolved fails closed. Any non-changeset subject
  fails closed too. An actor with no org passes the check so the
  create's own `organization_id is required` validation answers instead
  of a bare Forbidden.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts
  alias FluxVale.Billing.Wallet

  @impl Ash.Policy.Check
  def describe(_opts), do: "the org's wallet balance is positive"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case org_in_play(context.subject) do
      {:ok, org_id} -> org_funded?(org_id)
      # Creates that name no instance (the gateway —
      # SetOrganizationFromActor pins the actor's org moments later)
      # resolve the actor's personal org.
      :actor -> funded_via_actor?(actor)
      # Non-changeset subject, reload or org-resolution failure (row
      # gone, no resolvable org, DB down): fail closed.
      :error -> false
    end
  end

  @doc """
  The predicate: does this org's wallet hold a positive balance? A
  wallet-less org is unfunded (balance 0 by definition — the ledger is
  the balance).
  """
  @spec org_funded?(Ash.UUID.t()) :: boolean()
  def org_funded?(org_id) do
    case Wallet.get_by_organization(org_id, authorize?: false) do
      {:ok, wallet} ->
        {:ok, loaded} = Ash.load(wallet, :balance, authorize?: false)
        (loaded.balance || 0) > 0

      {:error, _no_wallet} ->
        false
    end
  end

  # Create vs update by the ACTION's shape, never by a nil attribute: a
  # forged `organization_id: nil` on an update must not reroute the gate
  # to the actor's personal org — the wallet an in-process caller
  # controls. Updates carry the loaded record, but an in-process caller
  # controls that struct, so the org comes off a FRESH DB read of the
  # row, never the in-memory attribute. Creates carry no row yet → the
  # actor path. Any non-changeset subject (a query, an action input)
  # fails closed.
  defp org_in_play(%Ash.Changeset{action_type: :create} = changeset),
    do: create_org_id(changeset)

  # Atomic changesets carry this placeholder — Ash.reload would raise
  # on it — and no org resolves from it: fail closed.
  defp org_in_play(%Ash.Changeset{data: %Ash.Changeset.OriginalDataNotAvailable{}}),
    do: :error

  defp org_in_play(%Ash.Changeset{data: data}) do
    case Ash.reload(data, authorize?: false) do
      {:ok, fresh_row} -> row_org(fresh_row)
      {:error, _reload_failure} -> :error
    end
  end

  defp org_in_play(_subject), do: :error

  # A create that NAMES its instance (BackupSetting) resolves the org
  # from THAT instance — the row's org — never the actor's personal
  # one (a team-org instance must not answer on the member's wallet,
  # either direction). Attribute first, then argument, covering both
  # intake shapes.
  #
  # Accepted-with-rationale: a create whose input carries a
  # relationship-shaped instance instead of a concrete `instance_id`
  # does not reach this resolver — the action's own Required
  # validation answers (the orgless-actor posture), so the actor arm
  # is never consulted on a foreign org. Revisit trigger: the day
  # :create accepts relationship-shaped instances, resolve the org
  # from the relationship here.
  defp create_org_id(%Ash.Changeset{} = changeset) do
    instance_id =
      Ash.Changeset.get_attribute(changeset, :instance_id) ||
        Map.get(changeset.arguments, :instance_id)

    case instance_id do
      nil -> :actor
      instance_id -> instance_org_id(instance_id)
    end
  end

  # Fresh authorize-free read, the same fail-closed discipline as
  # updates: an instance that cannot resolve (deleted under the
  # changeset, a DB outage) answers :error, never the actor path.
  defp instance_org_id(instance_id) do
    case Ash.get(FluxVale.Infrastructure.Instance, instance_id, authorize?: false) do
      {:ok, %{organization_id: org_id}} when not is_nil(org_id) -> {:ok, org_id}
      _unresolved -> :error
    end
  end

  # The org rides the row directly (organization_id) or THROUGH the
  # row's instance (BackupSetting belongs to :instance, not the
  # organization — resolve it one hop along the same FK the policies
  # read). A row whose org cannot be resolved fails closed.
  defp row_org(%{organization_id: org_id}) when not is_nil(org_id), do: {:ok, org_id}

  defp row_org(row) do
    case Ash.load(row, :instance, authorize?: false) do
      {:ok, %{instance: %{organization_id: org_id}}} when not is_nil(org_id) ->
        {:ok, org_id}

      # coveralls-ignore-start - defensive: the belongs_to FK guarantees
      # the instance (a cascade never leaves the row behind it) and the
      # instance's organization_id is not nullable, so the load either
      # resolves or the DB is gone — which ExUnit cannot simulate
      # (DBConnection reconnects — the repo's cluster-level stance).
      _unresolved ->
        :error
        # coveralls-ignore-stop
    end
  end

  # The actor's org is what SetOrganizationFromActor will pin the row
  # with — the same wallet the created instance will accrue against.
  # No org at all passes (see the moduledoc).
  defp funded_via_actor?(actor) do
    case Accounts.personal_org_for_user(actor.id, authorize?: false) do
      {:ok, org} -> org_funded?(org.id)
      :none -> true
    end
  end
end

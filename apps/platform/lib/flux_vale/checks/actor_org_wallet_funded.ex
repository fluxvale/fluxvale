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
  caller's own wallet). Creates resolve the actor's personal org — the
  same lookup `SetOrganizationFromActor` pins the row with moments
  later. Updates re-read the ROW from the database: an in-process
  caller controls the changeset's in-memory struct, and the gate must
  not be caller-controlled. The row's org rides `organization_id`
  directly, or THROUGH the row's instance (a `BackupSetting` belongs to
  its instance, not the organization); a row whose org cannot be
  resolved fails closed. An actor with no org passes the check so the
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
    case row_org_id(context.subject) do
      :create -> funded_via_actor?(actor)
      {:ok, org_id} -> org_funded?(org_id)
      # Reload or org-resolution failure (row gone, no resolvable org,
      # DB down): fail closed.
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
  # actor path.
  defp row_org_id(%Ash.Changeset{action_type: :create}), do: :create

  defp row_org_id(%Ash.Changeset{data: data}) do
    case Ash.reload(data, authorize?: false) do
      {:ok, fresh_row} -> row_org(fresh_row)
      {:error, _reload_failure} -> :error
    end
  end

  defp row_org_id(_subject), do: :create

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

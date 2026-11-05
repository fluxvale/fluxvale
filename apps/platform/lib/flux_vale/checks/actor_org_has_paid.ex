defmodule FluxVale.Checks.ActorOrgHasPaid do
  @moduledoc """
  Policy check: the org in play is past the paid gate — REAL MONEY at
  least once (one completed $1+ top-up, ever), OR the operator's
  paywall waiver. Private-access enablement is a paid add-on's surface:
  the $3 welcome credit every org gets at signup must not unlock it (a
  bot gets welcome credits, never a card). The test is the ledger's
  shape, not the balance: reason `:purchase` is the payment-webhook's
  reason (`CreditWallet`), so goodwill/adjustment grants never
  qualify. Refunds post compensating debits (`ReverseEntry`) that this
  check ignores — a paid org stays paid. Wired beside the funded check
  at AccessGateway `create`/`resume` and BackupSetting create/update;
  the backup-run guard and the panels read the same predicate.

  The waiver is the operator's designated-org path (testers, friends,
  demos): a `paywall_waived` boolean on the wallet, flipped from /admin
  by a platform admin. It satisfies THIS gate only — the funded
  (balance > 0) checks read nothing but the ledger, and the waiver
  never moves money (no rows, no balance, nothing spendable). Has-paid
  for revenue purposes remains the ledger's `:purchase` rows alone:
  the waiver is never a purchase row, so conversion queries count only
  real payers.

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
  of a bare Forbidden (the ActorOrgWalletFunded stance).
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet

  require Ash.Query

  # The $1 floor in whole cents. Product decision: ONE real payment
  # event of at least $1 ever unlocks — welcome/goodwill credits do not
  # (the reason dimension is what separates a card from a bot).
  @min_purchase_cents 100

  @impl Ash.Policy.Check
  def describe(_opts), do: "the org is past the paid gate (paid once, or operator-waived)"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case org_in_play(context.subject) do
      {:ok, org_id} -> org_paid?(org_id)
      # Creates that name no instance (the gateway —
      # SetOrganizationFromActor pins the actor's org moments later)
      # resolve the actor's personal org.
      :actor -> paid_via_actor?(actor)
      # Non-changeset subject, reload or org-resolution failure (row
      # gone, no resolvable org, DB down): fail closed.
      :error -> false
    end
  end

  @doc """
  The predicate: is this org past the paid gate — a qualifying purchase
  credit on the ledger, OR the wallet carries the operator's paywall
  waiver? A wallet-less org has neither (there is no ledger to hold a
  purchase, no wallet to hold a waiver).
  """
  @spec org_paid?(Ash.UUID.t()) :: boolean()
  def org_paid?(org_id) do
    case Wallet.get_by_organization(org_id, authorize?: false) do
      {:ok, wallet} -> wallet.paywall_waived or purchase_credited?(wallet)
      {:error, _no_wallet} -> false
    end
  end

  # authorize?: false — the check IS the authorization (the
  # ActorOrgWalletFunded posture).
  defp purchase_credited?(wallet) do
    floor = @min_purchase_cents

    LedgerEntry
    |> Ash.Query.filter(
      wallet_id == ^wallet.id and type == :credit and reason == :purchase and amount >= ^floor
    )
    |> Ash.exists?(authorize?: false)
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
  # with — the same wallet the created gateway bills. No org at all
  # passes (see the moduledoc).
  defp paid_via_actor?(actor) do
    case Accounts.personal_org_for_user(actor.id, authorize?: false) do
      {:ok, org} -> org_paid?(org.id)
      :none -> true
    end
  end
end

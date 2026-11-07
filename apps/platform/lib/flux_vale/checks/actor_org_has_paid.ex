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

  The org in play resolves through `FluxVale.Checks.OrgInPlay` — the
  one resolver the wallet gates share (action shape over attribute
  guesses, fresh row reads for updates, instance-to-org hop for
  `BackupSetting`, fail closed on anything unresolvable). An actor
  with no org passes the check so the create's own
  `organization_id is required` validation answers instead of a bare
  Forbidden (the ActorOrgWalletFunded stance).
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Checks.OrgInPlay

  require Ash.Query

  # The $1 floor in whole cents. Product decision: ONE real payment
  # event of at least $1 ever unlocks — welcome/goodwill credits do not
  # (the reason dimension is what separates a card from a bot).
  @min_purchase_cents 100

  @impl Ash.Policy.Check
  def describe(_opts), do: "the org is past the paid gate (paid once, or operator-waived)"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case OrgInPlay.org_in_play(context.subject) do
      {:ok, org_id} -> org_paid?(org_id)
      # Creates that name neither an instance nor an org resolve the
      # actor's personal org.
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

  # The actor's org is the fallback for creates that name neither an
  # instance nor an org — the same wallet the tenancy change's default
  # pins. No org at all passes (see the moduledoc).
  defp paid_via_actor?(actor) do
    case Accounts.personal_org_for_user(actor.id, authorize?: false) do
      {:ok, org} -> org_paid?(org.id)
      :none -> true
    end
  end
end

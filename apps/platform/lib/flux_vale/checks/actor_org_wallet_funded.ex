defmodule FluxVale.Checks.ActorOrgWalletFunded do
  @moduledoc """
  Policy check: the org in play has a wallet balance > 0 — #124's
  deploy gate. Policy-land, not UI-land, so the API can't walk around
  it; wired to Instance `create` (new deploys) and `start` (resuming
  spends too — create-while-positive, stop, start-at-zero would
  otherwise route around the gate).

  Since #869 the check is the funded gate OR the operator's paywall
  waiver: a wallet carrying `paywall_waived` (admin-flipped from
  /admin) passes at any balance, so a waived org can run the owner
  stack at zero. The waiver is not money — no ledger rows, nothing
  spendable — and never qualifies as a purchase (the paid-once gate's
  revenue test stays the ledger's `:purchase` rows). Non-waived
  semantics are unchanged: balance > 0 still decides.

  The org in play resolves through `FluxVale.Checks.OrgInPlay` — the
  one resolver the wallet gates share (action shape over attribute
  guesses, fresh row reads for updates, instance-to-org hop for
  `BackupSetting`, fail closed on anything unresolvable). An actor
  with no org passes the check so the create's own
  `organization_id is required` validation answers instead of a bare
  Forbidden.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts
  alias FluxVale.Billing.Wallet
  alias FluxVale.Checks.OrgInPlay

  @impl Ash.Policy.Check
  def describe(_opts), do: "the org's wallet is funded (positive balance) or operator-waived"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case OrgInPlay.org_in_play(context.subject) do
      {:ok, org_id} -> org_funded?(org_id)
      # Creates that name neither an instance nor an org resolve the
      # actor's personal org.
      :actor -> funded_via_actor?(actor)
      # Non-changeset subject, reload or org-resolution failure (row
      # gone, no resolvable org, DB down): fail closed.
      :error -> false
    end
  end

  @doc """
  The predicate: is this org funded — a positive wallet balance, OR
  the wallet carries the operator's paywall waiver (#869)? A
  wallet-less org is unfunded (no balance, no waiver).
  """
  @spec org_funded?(Ash.UUID.t()) :: boolean()
  def org_funded?(org_id) do
    case Wallet.get_by_organization(org_id, authorize?: false) do
      {:ok, wallet} ->
        # The waiver short-circuits the ledger SUM (#869): a waived org
        # is funded at any balance, so the aggregate load below only
        # runs for unwaived orgs.
        wallet.paywall_waived or positive_balance?(wallet)

      {:error, _no_wallet} ->
        false
    end
  end

  # The balance read (a ledger aggregate) runs only past the waiver.
  defp positive_balance?(wallet) do
    {:ok, loaded} = Ash.load(wallet, :balance, authorize?: false)

    (loaded.balance || 0) > 0
  end

  # The actor's org is the fallback for creates that name neither an
  # instance nor an org — the same wallet the tenancy change's default
  # pins. No org at all passes (see the moduledoc).
  defp funded_via_actor?(actor) do
    case Accounts.personal_org_for_user(actor.id, authorize?: false) do
      {:ok, org} -> org_funded?(org.id)
      :none -> true
    end
  end
end

defmodule FluxVale.Checks.ActorOrgWalletFunded do
  @moduledoc """
  Policy check: the org in play has a wallet balance > 0 — #124's
  deploy gate. Policy-land, not UI-land, so the API can't walk around
  it; wired to Instance `create` (new deploys) and `start` (resuming
  spends too — create-while-positive, stop, start-at-zero would
  otherwise route around the gate).

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
  def describe(_opts), do: "the org's wallet balance is positive"

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

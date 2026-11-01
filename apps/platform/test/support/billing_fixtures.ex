defmodule FluxVale.TestSupport.BillingFixtures do
  @moduledoc """
  Preconditions for Billing tests (#120): an org (its wallet provisioned
  on demand through `Billing.ensure_wallet/1`) funded through the posting
  operations — test data rides the actions, mirroring production callers.

  Orgs here are built directly, not through the JIT provisioning path: the
  welcome grant (#122) rides provisioning, and these fixtures want exact
  balances. A member is attached so the member-scoped read policies have
  an actor.
  """

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures

  @doc """
  `{org, wallet}` with the wallet funded to `balance_cents` (default
  10_000¢) via a grant. Pass `org:` to reuse an org.
  """
  @spec funded_wallet!(keyword()) :: {Organization.t(), Billing.Wallet.t()}
  def funded_wallet!(opts \\ []) do
    org = Keyword.get(opts, :org) || elem(grant_free_org!(), 0)

    {:ok, wallet} = Billing.ensure_wallet(org)

    balance_cents = Keyword.get(opts, :balance_cents, 10_000)

    if balance_cents > 0 do
      # :adjustment, not the default :welcome — fixture funding is not a
      # signup grant; the reason is what keeps the ledger reconcilable.
      {:ok, _grant} = Billing.grant_credits(wallet, balance_cents, reason: :adjustment)
    end

    {org, wallet}
  end

  @doc """
  Marks the org as PAID — one $1+ `:purchase` credit through the
  payment-webhook seam (`Billing.credit_wallet/3`). The paid-once gate
  on private-access enablement reads exactly this ledger shape; the
  other fixtures fund via welcome/adjustment credits, which
  deliberately never qualify.
  """
  @spec mark_paid!(Organization.t() | Billing.Wallet.t()) :: Billing.LedgerEntry.t()
  def mark_paid!(target) do
    {:ok, entry} = Billing.credit_wallet(target, 100)
    entry
  end

  @doc """
  Marks a JIT-provisioned user's personal org as PAID — one $1+ top-up
  posted through the payment-webhook seam on top of the welcome wallet.
  The precondition the backup gates read: configuring/enabling backups
  and running them require the org to have paid once. Returns the org.
  """
  @spec mark_user_paid!(User.t()) :: Organization.t()
  def mark_user_paid!(%User{} = user) do
    {:ok, org} = Accounts.personal_org_for_user(user.id, authorize?: false)
    {:ok, wallet} = Billing.ensure_wallet(org)
    mark_paid!(wallet)
    org
  end

  @doc """
  Debits the org's wallet to exactly zero — the funded-gate tests'
  precondition (the gate reads the live ledger). The ledger's unit is
  micro-cents, hence the ×10_000.
  """
  @spec drain_wallet!(Organization.t()) :: :ok
  def drain_wallet!(org) do
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, balance} = Billing.balance(wallet, authorize?: false)
    {:ok, _drain} = Billing.debit_wallet(wallet, balance * 10_000)

    :ok
  end

  @doc """
  `{org, owner}` without the JIT provisioning path — no welcome grant
  (#122), so balance math stays exact. `funded_wallet!/1` builds on it;
  concurrency tests reuse it for the committed-row ids they clean up.
  """
  @spec grant_free_org!() :: {Organization.t(), User.t()}
  def grant_free_org! do
    # authorize?: false — system-op posture, the same bootstrap stance as
    # seeds (memberships are system-created; see the Membership resource).
    org =
      Organization.create!(
        %{
          name: "billing-fixture",
          slug: "billing-#{System.unique_integer([:positive])}"
        },
        authorize?: false
      )

    owner = AccountsFixtures.user!()

    Membership.create!(
      %{organization_id: org.id, user_id: owner.id, role: :owner},
      authorize?: false
    )

    {org, owner}
  end
end

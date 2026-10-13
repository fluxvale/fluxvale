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

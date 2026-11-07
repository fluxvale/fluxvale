# Dev-only capture setup for the admin wallets surface (#501). RESETS
# its own prior rows (slug prefix billing-capture-), then builds one
# deterministic state: a healthy funded wallet with a mixed ledger and
# a reversed goodwill pair, an unpaid waived wallet, a negative wallet
# anchored on the destroy clock, an untouched wallet (the ledger's
# empty state), and a waived PAID org for the AshAdmin before/after
# pair. Prints the admin session token and every wallet id the capture
# script needs.
#
# Run from apps/platform: mix run ../e2e/admin_billing_seed.exs

alias FluxVale.Accounts.Membership
alias FluxVale.Accounts.Organization
alias FluxVale.Billing
alias FluxVale.Billing.LedgerEntry
alias FluxVale.Billing.Wallet
alias FluxVale.Identity.User

import Ecto.Query
alias FluxVale.Repo

# Reset this script's own prior rows (the dev DB keeps everything
# else). The ledger is append-only and wallets carry no destroy, so
# the capture reset rides the data layer directly — dev-capture
# tooling, not a product path. FK order: entries, wallets,
# memberships, orgs.
org_ids = Repo.all(from(o in "organizations", where: like(o.slug, "billing-capture-%"), select: o.id))

wallet_ids =
  Repo.all(from(w in "billing_wallets", where: w.organization_id in ^org_ids, select: w.id))

{_, nil} = Repo.delete_all(from(e in "billing_ledger_entries", where: e.wallet_id in ^wallet_ids))
{_, nil} = Repo.delete_all(from(w in "billing_wallets", where: w.id in ^wallet_ids))
{_, nil} = Repo.delete_all(from(m in "memberships", where: m.organization_id in ^org_ids))
{_, nil} = Repo.delete_all(from(o in "organizations", where: o.id in ^org_ids))

# The seed admin (seeds.exs creates it at bin/seed; get-or-create keeps
# this script safe on a fresh dev DB).
admin =
  case User.get_by_email("admin@fluxvale.com", authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
  end

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

org! = fn name ->
  org =
    Organization.create!(
      %{name: name, slug: "billing-capture-#{suffix}-#{System.unique_integer([:positive])}"},
      authorize?: false
    )

  {:ok, wallet} = Billing.ensure_wallet(org)
  {org, wallet}
end

# 1. Healthy: funded, a mixed ledger, and a reversed goodwill pair.
{healthy_org, healthy} = org!.("Northwind Labs")

{:ok, _purchase} =
  Billing.grant_credits(healthy, 4_000, reason: :purchase, idempotency_key: "polar:cap-#{suffix}")

{:ok, _usage} = Billing.debit_wallet(healthy, 1_234 * 10_000)
{:ok, _adjust} = Billing.grant_credits(healthy, 900, reason: :adjustment)
{:ok, goodwill} = Billing.grant_credits(healthy, 250, reason: :adjustment)
{:ok, _reversal} = Billing.reverse_entry(goodwill)

# 2. Waived: funded and the paywall waiver flipped (no purchase rows,
# so the removal copy is the closes-again branch).
{waived_org, waived} = org!.("Acme Collective")
{:ok, _fund} = Billing.grant_credits(waived, 5_000, reason: :adjustment)
{:ok, _waived} = Wallet.set_waiver(waived, %{paywall_waived: true}, actor: admin)

# 3. Negative: below zero, anchored on the destroy clock.
{negative_org, negative} = org!.("Quill and Co")
{:ok, _start} = Billing.grant_credits(negative, 300, reason: :adjustment)
{:ok, _drain} = Billing.debit_wallet(negative, 2_500 * 10_000)

negative
|> Ash.Changeset.for_update(
  :set_ladder_state,
  %{negative_since: DateTime.add(DateTime.utc_now(), -3, :day)},
  authorize?: false
)
|> Ash.update!()

# 4. Untouched: provisioned, never posted to — the ledger's empty state.
{_empty_org, empty} = org!.("Quiet Org")

# 5. The before/after pair's org: WAIVED and PAID, so the AshAdmin
# before (the checked checkbox) and the after (the removal confirm)
# talk about the same named org.
{pair_org, pair} = org!.("Beacon Works")
{:ok, _fund} = Billing.grant_credits(pair, 2_000, reason: :adjustment)
{:ok, _purchase} = Billing.credit_wallet(pair, 100)
{:ok, _waived} = Wallet.set_waiver(pair, %{paywall_waived: true}, actor: admin)

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_HEALTHY_WALLET_ID=#{healthy.id}")
IO.puts("FV_WAIVED_WALLET_ID=#{waived.id}")
IO.puts("FV_NEGATIVE_WALLET_ID=#{negative.id}")
IO.puts("FV_EMPTY_WALLET_ID=#{empty.id}")
IO.puts("FV_PAIR_WALLET_ID=#{pair.id}")
IO.puts("FV_PAIR_ORG=#{pair_org.name}")

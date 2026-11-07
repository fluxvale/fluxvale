# Dev-only capture setup for the admin wallets surface (#501): the
# seed platform admin plus three capture orgs — a healthy funded
# wallet with a mixed ledger (purchase, usage, adjustment, and a
# reversed goodwill pair), a waived wallet, and a negative wallet
# anchored on the destroy clock. Prints the admin session token and
# the wallet ids admin_billing_screenshot.mjs needs.
#
# Run from apps/platform: mix run ../e2e/admin_billing_seed.exs

alias FluxVale.Billing
alias FluxVale.Billing.Wallet
alias FluxVale.Identity.User

require Ash.Query

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

# {name, slug} — display names an operator would scan, slugs unique.
org! = fn name ->
  org =
    FluxVale.Accounts.Organization.create!(
      %{name: name, slug: "billing-capture-#{suffix}-#{System.unique_integer([:positive])}"},
      authorize?: false
    )

  {:ok, wallet} = Billing.ensure_wallet(org)
  {org, wallet}
end

anchor = fn wallet ->
  # The destroy clock's anchor is the sweep's own write (the ladder
  # markers are states actions cannot produce — the sweep tests' escape).
  wallet
  |> Ash.Changeset.for_update(
    :set_ladder_state,
    %{negative_since: DateTime.add(DateTime.utc_now(), -3, :day)},
    authorize?: false
  )
  |> Ash.update!()
end

# 1. Healthy: funded, a mixed ledger, and a reversed goodwill pair.
{healthy_org, healthy} = org!.("Northwind Labs")

{:ok, _purchase} =
  Billing.grant_credits(healthy, 4_000, reason: :purchase, idempotency_key: "polar:cap-#{suffix}")

{:ok, _usage} = Billing.debit_wallet(healthy, 1_234 * 10_000)
{:ok, _adjust} = Billing.grant_credits(healthy, 900, reason: :adjustment)
{:ok, goodwill} = Billing.grant_credits(healthy, 250, reason: :adjustment)
{:ok, _reversal} = Billing.reverse_entry(goodwill)

# 2. Waived: funded and the paywall waiver flipped.
{waived_org, waived} = org!.("Acme Collective")
{:ok, _fund} = Billing.grant_credits(waived, 5_000, reason: :adjustment)
{:ok, _waived} = Wallet.set_waiver(waived, %{paywall_waived: true}, actor: admin)

# 3. Negative: below zero, anchored on the destroy clock.
{negative_org, negative} = org!.("Quill and Co")
{:ok, _start} = Billing.grant_credits(negative, 300, reason: :adjustment)
{:ok, _drain} = Billing.debit_wallet(negative, 2_500 * 10_000)
anchor.(negative)

# 4. Untouched: provisioned, never posted to — the ledger's empty state.
{_empty_org, empty} = org!.("Quiet Org")

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_HEALTHY_WALLET_ID=#{healthy.id}")
IO.puts("FV_WAIVED_WALLET_ID=#{waived.id}")
IO.puts("FV_NEGATIVE_WALLET_ID=#{negative.id}")
IO.puts("FV_EMPTY_WALLET_ID=#{empty.id}")
IO.puts("FV_HEALTHY_ORG=#{healthy_org.name}")
IO.puts("FV_NEGATIVE_ORG=#{negative_org.name}")
IO.puts("FV_WAIVED_ORG=#{waived_org.name}")

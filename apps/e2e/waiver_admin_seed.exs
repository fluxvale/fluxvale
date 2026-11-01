# Dev-only capture setup for the paywall-waiver admin screenshots. Ensures
# the seed platform admin exists, builds one never-paid capture org with a
# wallet (welcome credit only), and prints the admin session token plus the
# wallet id waiver_admin_screenshot.mjs needs.
#
# Run from apps/platform: mix run ../e2e/waiver_admin_seed.exs

alias FluxVale.Accounts.Membership
alias FluxVale.Accounts.Organization
alias FluxVale.Billing
alias FluxVale.Identity.User

require Ash.Query

# The seed admin (seeds.ex creates it at bin/seed; get-or-create keeps this
# script safe on a fresh dev DB).
admin =
  case User.get_by_email("admin@fluxvale.com", authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
  end

# Random suffix: the dev DB keeps rows across runs (the paid_gate seed's
# stance) — emails and slugs must stay collision-free on their own.
suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

capture_user = User.create!("waiver-capture-#{suffix}@fluxvale.test", %{}, authorize?: false)

org =
  Organization.create!(
    %{name: "Capture Org #{suffix}", slug: "waiver-#{suffix}"},
    authorize?: false
  )

Membership.create!(
  %{organization_id: org.id, user_id: capture_user.id, role: :owner},
  authorize?: false
)

{:ok, wallet} = Billing.ensure_wallet(org)
{:ok, _welcome} = Billing.grant_credits(wallet, 300)

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

IO.puts("FV_TOKEN_ADMIN=#{token}")
IO.puts("FV_WALLET_ID=#{wallet.id}")
IO.puts("FV_ORG_NAME=#{org.name}")

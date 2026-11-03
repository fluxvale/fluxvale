# Dev-only capture setup for the #364 country-combobox screenshots:
# one user (fresh wallet) plus a COMPLETED top-up row so the wizard's
# receipt capture has something to land on. Prints the session token
# for s9_capture.mjs / s364_gif.mjs (FV_TOKEN) and the receipt's
# payment reference (FV_RECEIPT_REF).
#
# Run from apps/platform: mix run ../e2e/country_capture_seed.exs

alias FluxVale.Billing
alias FluxVale.Billing.Topup
alias FluxVale.Identity.User

require Ash.Query

# Random suffix, not unique_integer: separate `mix run` processes
# restart the counter, and the dev DB keeps rows across runs — the
# emails and references must stay collision-free on their own.
suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

user = User.create!("capture-#{suffix}@fluxvale.test", %{}, authorize?: false)

{:ok, org} = FluxVale.Accounts.personal_org_for_user(user.id, actor: user)
{:ok, _wallet} = Billing.ensure_wallet(org)

# A completed $5 top-up — the receipt card the capture script reads.
reference = "pr_s364_#{suffix}"

{:ok, topup} =
  Topup.create(
    %{
      organization_id: org.id,
      amount_cents: 500,
      buyer_email: "jane@example.com",
      buyer_name: "Jane Doe",
      billing_country: "DE"
    },
    authorize?: false
  )

{:ok, _attached} =
  Topup.attach_checkout(topup, %{payment_request_id: reference}, authorize?: false)

{:ok, _completed} =
  Billing.complete_topup(%{
    payment_request_id: reference,
    payment_id: "pay_s364_#{suffix}",
    amount_cents: 500,
    idempotency_key: "hitpay:pay_s364_#{suffix}"
  })

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)

# The org's page URL rides the username-derived slug (see
# ProvisionPersonalOrg) — the capture script's org-billing surface.
IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_ORG_SLUG=#{org.slug}")
IO.puts("FV_RECEIPT_REF=#{reference}")

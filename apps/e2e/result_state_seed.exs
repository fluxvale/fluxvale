# Dev-only capture setup for the top-up result states (#377). Creates
# one user with a drained-then-credited wallet: a completed top-up
# (the success card: amount + resulting balance) and a still-pending
# one (the honest confirming card — no provider configured in dev, so
# reconciliation degrades to pending, exactly the presentation state).
# Prints the session token for result_state_screenshot.mjs.
#
# Run from apps/platform: mix run ../e2e/result_state_seed.exs

alias FluxVale.Billing
alias FluxVale.Billing.Topup
alias FluxVale.Identity.User
alias FluxVale.Identity.UserEmail

require Ash.Query

# Random, not unique_integer: separate `mix run` processes restart the
# counter, and the dev DB keeps rows across runs.
suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

user = User.create!("result-capture-#{suffix}@fluxvale.test", %{}, authorize?: false)

# A verified primary address — the session gate severs users with
# none (AccessRules.ensure_allowed_user), and the capture session is
# minted straight from the JWT. The create action already adds the
# address as an unverified row; fetch-or-add, then verify + promote.
existing =
  UserEmail
  |> Ash.Query.filter(address == ^user.email)
  |> Ash.read!(authorize?: false)

row =
  case existing do
    [row | _rest] -> row
    [] -> UserEmail.add!(user.email, %{user: user}, authorize?: false)
  end

{:ok, verified} = UserEmail.mark_verified(row, authorize?: false)
{:ok, _primary} = UserEmail.set_primary(verified, actor: user)

{:ok, org} = FluxVale.Accounts.personal_org_for_user(user.id, authorize?: false)
{:ok, wallet} = Billing.ensure_wallet(org)

# Pin the balance at exactly the credit: the success card's "balance
# is now" line reads clean in the capture.
{:ok, balance} = Billing.balance(wallet, authorize?: false)

if balance > 0 do
  {:ok, _drained} = Billing.debit_wallet(wallet, balance * 10_000)
end

# The success state: $50.00 credited through the real operation.
# payment_request_id is globally unique — the ids carry the run's
# suffix so repeated captures never collide.
done_id = "co_done_#{suffix}"
pending_id = "co_pending_#{suffix}"

{:ok, done} =
  Topup.create(
    %{organization_id: org.id, amount_cents: 5000, buyer_email: "jane@example.com"},
    authorize?: false
  )

{:ok, _attached} =
  Topup.attach_checkout(done, %{payment_request_id: done_id}, authorize?: false)

{:ok, _completed} =
  Billing.complete_topup(%{
    payment_request_id: done_id,
    payment_id: done_id,
    amount_cents: 5000,
    idempotency_key: "polar:#{done_id}"
  })

# The confirming state: a pending row whose reconciliation can't
# resolve in dev (no provider credentials) — the honest resting card.
{:ok, pending} =
  Topup.create(
    %{organization_id: org.id, amount_cents: 2500, buyer_email: "jane@example.com"},
    authorize?: false
  )

{:ok, _pending_attached} =
  Topup.attach_checkout(pending, %{payment_request_id: pending_id}, authorize?: false)

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_CHECKOUT_DONE=#{done_id}")
IO.puts("FV_CHECKOUT_PENDING=#{pending_id}")

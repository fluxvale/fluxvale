# Dev-only capture setup for the paid-once gate screenshots. Creates two
# never-paid users (JIT personal org = welcome credit only), seeds a
# :suspended gateway row for the second (dev screenshot data — the
# create action needs the provider, which no dev cluster runs), and
# prints the two session tokens for paid_gate_screenshot.mjs.
#
# Run from apps/platform: mix run ../e2e/paid_gate_seed.exs

alias FluxVale.Identity.User
alias FluxVale.Identity.UserEmail
alias FluxVale.Infrastructure.AccessGateway

require Ash.Query

# Random, not unique_integer: separate `mix run` processes restart the
# counter, and the dev DB keeps rows across runs — the emails and the
# hostname must stay collision-free on their own.
suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

user_a = User.create!("capture-a-#{suffix}@fluxvale.test", %{}, authorize?: false)
user_b = User.create!("capture-b-#{suffix}@fluxvale.test", %{}, authorize?: false)

Enum.each([user_a, user_b], fn user ->
  existing =
    UserEmail
    |> Ash.Query.filter(address == ^user.email)
    |> Ash.read!(authorize?: false)

  row =
    case existing do
      [row | _] ->
        row

      [] ->
        {:ok, added} = UserEmail.add(user.email, %{user: user}, authorize?: false)
        added
    end

  {:ok, verified} = UserEmail.mark_verified(row, authorize?: false)
  {:ok, _primary} = UserEmail.set_primary(verified, actor: user)
end)

# user_b's personal org carries a suspended gateway — the blocked
# resume surface. Ash.Seed.seed!: no action can produce a :suspended row
# without the provider (the tests' documented seed! exception).
{:ok, personal_b} = FluxVale.Accounts.personal_org_for_user(user_b.id, authorize?: false)

Ash.Seed.seed!(AccessGateway, %{
  organization_id: personal_b.id,
  # 8 hex chars — the row's \Afv-[0-9a-f]{8}\z constraint; the random
  # suffix keeps repeated capture runs off the unique_hostname identity.
  hostname: "fv-" <> String.downcase(suffix),
  monthly_cents: 200,
  state: :suspended,
  # The real suspend path's copy (Suspend.change) — the capture must
  # not show a status line the product never writes.
  status_message: "Access paused — top up to resume",
  tailnet_domain: "capture-#{suffix}.ts.net"
})

{:ok, token_a, _} = AshAuthentication.Jwt.token_for_user(user_a)
{:ok, token_b, _} = AshAuthentication.Jwt.token_for_user(user_b)

IO.puts("FV_TOKEN_A=#{token_a}")
IO.puts("FV_TOKEN_B=#{token_b}")

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

suffix = System.unique_integer([:positive])

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
  hostname: "fv-0000000#{rem(suffix, 10)}",
  monthly_cents: 200,
  state: :suspended,
  status_message: "Suspended — the balance ran out",
  tailnet_domain: "capture-#{suffix}.ts.net"
})

{:ok, token_a, _} = AshAuthentication.Jwt.token_for_user(user_a)
{:ok, token_b, _} = AshAuthentication.Jwt.token_for_user(user_b)

IO.puts("FV_TOKEN_A=#{token_a}")
IO.puts("FV_TOKEN_B=#{token_b}")

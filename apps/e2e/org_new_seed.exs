# Dev-only capture setup for the org creation page (#408): one fresh
# user with a verified primary address — the session gate severs users
# with none. The JIT personal org rides User.create as always (one org
# + owner membership); no team orgs are written, and the capture
# scripts type a name but never submit, so nothing beyond that seed
# shape lands. Prints the session token for org_new_screenshot.mjs /
# org_new_gif.mjs.
#
# Run from apps/platform: mix run ../e2e/org_new_seed.exs

alias FluxVale.Identity.User
alias FluxVale.Identity.UserEmail

require Ash.Query

# Random, not unique_integer: separate `mix run` processes restart the
# counter, and the dev DB keeps rows across runs.
suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

user = User.create!("org-new-capture-#{suffix}@fluxvale.test", %{}, authorize?: false)

# A verified primary address — AccessRules.ensure_allowed_user severs
# users with none (the result_state_seed posture).
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

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)

IO.puts("FV_TOKEN=#{token}")

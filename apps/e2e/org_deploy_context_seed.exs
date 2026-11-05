# Dev-only capture setup for the org-context deploy picker (#408) —
# one user with a personal org AND a team org (the picker's two rows),
# plus a catalog app to enter the wizard from. Prints the session
# token and the app slug for org_deploy_context_shots.mjs.
#
# Run from apps/platform: mix run ../e2e/org_deploy_context_seed.exs

alias FluxVale.Accounts
alias FluxVale.Billing
alias FluxVale.Catalog.App
alias FluxVale.Catalog.AppVersion
alias FluxVale.Catalog.Category
alias FluxVale.Identity.User
alias FluxVale.Identity.UserEmail
alias FluxVale.Pricing.Size

require Ash.Query

# Random, not unique_integer: separate `mix run` processes restart the
# counter, and the dev DB keeps rows across runs — the emails must stay
# collision-free on their own.
suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

user = User.create!("capture-org-#{suffix}@fluxvale.test", %{}, authorize?: false)

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

# The picker's second row: a team org the actor owns (the action's own
# seam — the same call the UI makes), wallet-funded so a capture run
# could actually deploy into it.
{:ok, team} =
  Accounts.create_organization(user, %{
    name: "Acme Team",
    slug: "acme-team-#{suffix}"
  })

{:ok, wallet} = Billing.ensure_wallet(team)
{:ok, _grant} = Billing.grant_credits(wallet, 10_000, reason: :adjustment)

# The catalog chain the wizard entry needs (the fixtures' shape — dev
# screenshot data, authorize?: false).
category =
  Category.create!(%{name: "Org Ctx #{suffix}", slug: "orgctx-#{suffix}"},
    authorize?: false
  )

app =
  App.create!(
    %{
      name: "OrgCtx App #{suffix}",
      slug: "orgctx-#{suffix}",
      tagline: "capture app",
      description: "capture app",
      file_access: false,
      category_id: category.id
    },
    authorize?: false
  )

size =
  Size.create!(
    %{
      slug: "capture-orgctx-#{suffix}",
      cpu_cores: Decimal.new("0.5"),
      memory_mb: 256,
      storage_gb: 10,
      monthly_cents: 100,
      stopped_monthly_cents: 10
    },
    authorize?: false
  )

version =
  AppVersion.create!(
    %{
      version: "1.0.0",
      image: "registry.example.com/orgctx:1.0.0",
      port: 3000,
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 256,
      default_storage_gb: 10,
      app_id: app.id,
      recommended_size_id: size.id,
      published_at: DateTime.utc_now()
    },
    authorize?: false
  )

{:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_APP_SLUG=#{app.slug}")
IO.puts("FV_TEAM_NAME=#{team.name}")
IO.puts("version=#{version.id}")

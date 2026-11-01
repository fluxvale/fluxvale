# Dev-only capture setup for the backup paid-gate screenshots. Three
# users: (a) never-paid (welcome credit only) with a running, deployed,
# UNCONFIGURED instance — the setup card's blocked callout; (b) paid
# once, balance drained to zero, running instance with a settings row —
# the configured card's empty-balance callout and the "Back up now"
# refusal; (c) never-paid with a settings row — the configured card's
# never-paid callout (the legacy/lapsed shape). Prints the three
# session tokens for backup_gate_screenshot.mjs.
#
# Run from apps/platform: mix run ../e2e/backup_gate_seed.exs

alias FluxVale.Billing
alias FluxVale.Catalog.App
alias FluxVale.Catalog.AppVersion
alias FluxVale.Catalog.Category
alias FluxVale.Pricing.Size
alias FluxVale.Identity.User
alias FluxVale.Identity.UserEmail
alias FluxVale.Infrastructure.BackupSetting
alias FluxVale.Infrastructure.Instance
alias FluxVale.Infrastructure.Operations.InstanceK8s

require Ash.Query

# Random, not unique_integer: separate `mix run` processes restart the
# counter, and the dev DB keeps rows across runs — the emails must stay
# collision-free on their own.
suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

user_a = User.create!("capture-a-#{suffix}@fluxvale.test", %{}, authorize?: false)
user_b = User.create!("capture-b-#{suffix}@fluxvale.test", %{}, authorize?: false)
user_c = User.create!("capture-c-#{suffix}@fluxvale.test", %{}, authorize?: false)

Enum.each([user_a, user_b, user_c], fn user ->
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

# A catalog chain the instances point at (the fixtures' shape — dev
# screenshot data, authorize?: false). The slug base is the random
# suffix, not a process-local counter: `mix run` restarts the counter,
# and the dev DB keeps rows between runs.
n = suffix

category =
  Category.create!(%{name: "Tools #{n}", slug: "tools-#{n}", description: "capture category"},
    authorize?: false
  )

app =
  App.create!(
    %{
      name: "App #{n}",
      slug: "app-#{n}",
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
      slug: "capture-#{n}",
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
      image: "registry.example.com/app:1.0",
      port: 3000,
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 256,
      default_storage_gb: 10,
      app_id: app.id,
      recommended_size_id: size.id
    },
    authorize?: false
  )

# The canonical dev cluster — get_or_create "local" (the local seed's
# row). Creating a second cluster breaks the exactly-one invariant the
# instance creates resolve against (ADR-0006).
FluxVale.Seeds.seed_local_cluster!()

# Both instances: action-created (the JIT org's welcome wallet funds
# the create), namespace pinned and walked to :running — the state the
# panel's actions live in. The deploy trigger's cluster calls fail
# loudly in the log (no dev cluster); the row is what the capture reads.
Enum.each([user_a, user_b, user_c], fn user ->
  instance =
    Instance.create!(
      %{name: "Capture #{System.unique_integer([:positive])}", app_version_id: version.id},
      actor: user
    )

  {:ok, deploying} = InstanceK8s.update_status(instance, :deploying, nil)

  # The namespace is write-once (the deploy action owns it) — force it
  # the way the test fixtures' pin! does (dev capture data).
  pinned =
    deploying
    |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:namespace, "fluxvale-app-#{instance.id}")
    |> Ash.update!()

  Enum.reduce([:starting, :running], pinned, fn status, acc ->
    {:ok, next} = InstanceK8s.update_status(acc, status, nil)
    next
  end)
end)

# (b) is PAID once (a real $1 top-up through the payment-webhook seam)
# and then drained to zero — the paid-but-unfunded run refusal.
{:ok, personal_b} = FluxVale.Accounts.personal_org_for_user(user_b.id, authorize?: false)
{:ok, wallet_b} = Billing.ensure_wallet(personal_b)
{:ok, _purchase} = Billing.credit_wallet(wallet_b, 100)

{:ok, balance_b} = Billing.balance(wallet_b, authorize?: false)
{:ok, _drain} = Billing.debit_wallet(wallet_b, balance_b * 10_000)

# (b)'s and (c)'s settings rows: Ash.Seed.seed! — the row is
# ConfigureBackups' output and needs the namespace Secret no dev cluster
# runs (the tests' documented seed! exception).
instance_b =
  Instance
  |> Ash.Query.filter(organization_id == ^personal_b.id)
  |> Ash.read!(authorize?: false)
  |> List.first()

Ash.Seed.seed!(BackupSetting, %{
  instance_id: instance_b.id,
  endpoint: "https://account.r2.cloudflarestorage.com",
  bucket: "capture-backups",
  access_key_id: "AKIAIOSFODNN7EXAMPLE"
})

{:ok, personal_c} = FluxVale.Accounts.personal_org_for_user(user_c.id, authorize?: false)

instance_c =
  Instance
  |> Ash.Query.filter(organization_id == ^personal_c.id)
  |> Ash.read!(authorize?: false)
  |> List.first()

Ash.Seed.seed!(BackupSetting, %{
  instance_id: instance_c.id,
  endpoint: "https://account.r2.cloudflarestorage.com",
  bucket: "capture-backups",
  access_key_id: "AKIAIOSFODNN7EXAMPLE"
})

{:ok, token_a, _} = AshAuthentication.Jwt.token_for_user(user_a)
{:ok, token_b, _} = AshAuthentication.Jwt.token_for_user(user_b)
{:ok, token_c, _} = AshAuthentication.Jwt.token_for_user(user_c)

IO.puts("FV_TOKEN_A=#{token_a}")
IO.puts("FV_TOKEN_B=#{token_b}")
IO.puts("FV_TOKEN_C=#{token_c}")

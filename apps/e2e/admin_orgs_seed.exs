# Dev-only capture setup for the admin orgs surface (#501). RESETS its
# own prior rows (slug prefix orgs-capture-), then builds one
# deterministic state: a funded healthy org, a zero-balance org, a
# negative org anchored on the destroy clock, a member org with three
# instances (running / sleeping / stopped) for the detail capture, an
# untouched member org (the instances' empty state), a non-member org
# with an instance (the honest scope note), and a wallet-less org (the
# no-wallet note). Prints the admin session token and every org id the
# capture script needs.
#
# Run from apps/platform: mix run ../e2e/admin_orgs_seed.exs

alias FluxVale.Accounts.Membership
alias FluxVale.Accounts.Organization
alias FluxVale.Billing
alias FluxVale.Billing.Wallet
alias FluxVale.Catalog.App
alias FluxVale.Catalog.AppVersion
alias FluxVale.Catalog.Category
alias FluxVale.Identity.User
alias FluxVale.Infrastructure.Cluster
alias FluxVale.Infrastructure.Instance
alias FluxVale.Infrastructure.Operations.InstanceK8s
alias FluxVale.Pricing.Size

import Ecto.Query
alias FluxVale.Repo

# Reset this script's full capture subject: every capture-prefixed
# org on the dev DB (orgs-capture-, billing-capture-, gateways-capture-
# — any lane's leftovers read as live data in the list, and the list
# shows every org with a wallet). FK order: hostnames, instances,
# ledger entries, wallets, memberships, orgs (the ledger is
# append-only, so the capture reset rides the data layer directly —
# dev-capture tooling, not a product path).
org_ids =
  Repo.all(from(o in "organizations", where: like(o.slug, "%-capture-%"), select: o.id))

instance_ids =
  Repo.all(from(i in "instances", where: i.organization_id in ^org_ids, select: i.id))

wallet_ids =
  Repo.all(from(w in "billing_wallets", where: w.organization_id in ^org_ids, select: w.id))

Repo.delete_all(from(h in "instance_hostnames", where: h.instance_id in ^instance_ids))
Repo.delete_all(from(i in "instances", where: i.id in ^instance_ids))

{_, nil} =
  Repo.delete_all(from(e in "billing_ledger_entries", where: e.wallet_id in ^wallet_ids))

{_, nil} = Repo.delete_all(from(w in "billing_wallets", where: w.id in ^wallet_ids))
{_, nil} = Repo.delete_all(from(m in "memberships", where: m.organization_id in ^org_ids))

# The default hostname's access domain (ADR-0040) rides the org, and
# the gateways lane's leftovers carry gateways and their routes.
{_, nil} =
  Repo.delete_all(from(d in "access_domains", where: d.organization_id in ^org_ids))

{_, nil} =
  Repo.delete_all(
    from(r in "access_routes",
      where:
        r.gateway_id in ^Repo.all(
          from(g in "access_gateways", where: g.organization_id in ^org_ids, select: g.id)
        )
    )
  )

{_, nil} =
  Repo.delete_all(from(g in "access_gateways", where: g.organization_id in ^org_ids))

{_, nil} = Repo.delete_all(from(o in "organizations", where: o.id in ^org_ids))

# The seed admin (seeds.exs creates it at bin/seed; get-or-create keeps
# this script safe on a fresh dev DB). The create mirrors seeds.exs'
# own shape — the email rides the create params (the identity
# machinery's argument), not the removed users column.
admin =
  case User.get_by_email("admin@fluxvale.com", authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      User
      |> Ash.Changeset.for_create(:create, %{email: "admin@fluxvale.com", platform_role: :admin})
      |> Ash.create!(authorize?: false)
  end

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

# ResolveCluster pins THE single cluster row — the setup's local_seeds
# created it; get-or-create keeps this script safe on a fresh dev DB.
case Ash.read!(Cluster, authorize?: false) do
  [] ->
    Cluster.create!(%{name: "local"}, authorize?: false)

  [cluster] ->
    cluster

  _multiple ->
    raise "multiple cluster rows — ResolveCluster requires exactly one"
end

org! = fn name ->
  org =
    Organization.create!(
      %{name: name, slug: "orgs-capture-#{suffix}-#{System.unique_integer([:positive])}"},
      authorize?: false
    )

  {:ok, wallet} = Billing.ensure_wallet(org)
  {org, wallet}
end

member! = fn org ->
  Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
    authorize?: false
  )
end

# 1. Healthy: funded, positive balance.
{healthy_org, healthy} = org!.("Northwind Labs")
{:ok, _fund} = Billing.grant_credits(healthy, 4_000, reason: :adjustment)

# 2. Zero: a wallet that never posted — the funded gate's block state.
{_zero_org, zero} = org!.("Acme Collective")

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

# The instance fixtures' dev shape: category → app → size → version,
# through actions (test/support is :test-only; the same contracts here).
version! = fn ->
  n = System.unique_integer([:positive])

  category =
    Category.create!(
      %{name: "Capture #{n}", slug: "capture-#{n}", description: "capture fixture"},
      authorize?: false
    )

  app =
    App.create!(
      %{
        name: "Wiki #{suffix}",
        slug: "wiki-#{n}",
        tagline: "capture app",
        description: "capture app",
        file_access: false,
        category_id: category.id
      },
      authorize?: false
    )

  size =
    Size.create!(
      %{slug: "capture-#{n}", cpu_cores: Decimal.new("0.5"), memory_mb: 256, monthly_cents: 100},
      authorize?: false
    )

  AppVersion.create!(
    %{
      version: "1.2.#{rem(n, 100)}",
      image: "registry.example.com/wiki:1.2",
      port: 3000,
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 256,
      default_storage_gb: 1,
      app_id: app.id,
      recommended_size_id: size.id
    },
    authorize?: false
  )
end

# A member org with three instances in three resting states — the
# lifecycle strip and the sleep note's capture subject.
{instance_org, instance_wallet} = org!.("Beacon Works")
{:ok, _fund} = Billing.grant_credits(instance_wallet, 2_000, reason: :adjustment)
member!.(instance_org)

version = version!.()

# The create's org is the named context (the personal-org default
# would land these in the admin's own org) — the admin is a member of
# instance_org, so the create policy's membership fence passes.
instance! = fn name ->
  Instance.create!(
    %{name: name, app_version_id: version.id, organization_id: instance_org.id},
    actor: admin
  )
end

running = instance!.("Team Wiki")
sleeping = instance!.("Archive Wiki")
stopped = instance!.("Old Wiki")

{:ok, running} = InstanceK8s.update_status(running, :deploying, nil)
{:ok, running} = InstanceK8s.update_status(running, :starting, nil)
{:ok, running} = InstanceK8s.update_status(running, :running, nil)

{:ok, sleeping} = InstanceK8s.update_status(sleeping, :deploying, nil)
{:ok, sleeping} = InstanceK8s.update_status(sleeping, :starting, nil)
{:ok, sleeping} = InstanceK8s.update_status(sleeping, :running, nil)
{:ok, sleeping} = InstanceK8s.update_status(sleeping, :sleeping, nil)

{:ok, stopped} = InstanceK8s.update_status(stopped, :deploying, nil)
{:ok, stopped} = InstanceK8s.update_status(stopped, :starting, nil)
{:ok, stopped} = InstanceK8s.update_status(stopped, :running, nil)
{:ok, stopped} = InstanceK8s.update_status(stopped, :stopped, nil)

# 4. Untouched member org: the instances' empty state.
{empty_org, _empty_wallet} = org!.("Quiet Org")
member!.(empty_org)

# 5. Non-member org WITH an instance: the honest scope note. The
# instance belongs to a stranger the admin is not.
{hidden_org, hidden_wallet} = org!.("Stranger Org")
{:ok, _fund} = Billing.grant_credits(hidden_wallet, 10_000, reason: :adjustment)

stranger =
  User.create!(
    "orgs-capture-stranger-#{System.unique_integer([:positive])}@fluxvale.test",
    %{},
    authorize?: false
  )

Membership.create!(%{organization_id: hidden_org.id, user_id: stranger.id, role: :owner},
  authorize?: false
)

hidden_instance =
  Instance.create!(
    %{name: "Their Wiki", app_version_id: version.id, organization_id: hidden_org.id},
    actor: stranger
  )

# 6. Wallet-less org: team orgs provision at the first billing touch,
# so an org can legitimately have none yet.
nowallet_org =
  Organization.create!(
    %{name: "Daybreak Co-op", slug: "orgs-capture-#{suffix}-nowallet"},
    authorize?: false
  )

member!.(nowallet_org)

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_ORG_LIST_HEALTHY_WALLET=#{healthy.id}")
IO.puts("FV_ORG_LIST_ZERO_WALLET=#{zero.id}")
IO.puts("FV_ORG_LIST_NEGATIVE_WALLET=#{negative.id}")
IO.puts("FV_ORG_INSTANCES=#{instance_org.id}")
IO.puts("FV_ORG_EMPTY=#{empty_org.id}")
IO.puts("FV_ORG_HIDDEN=#{hidden_org.id}")
IO.puts("FV_ORG_NOWALLET=#{nowallet_org.id}")
IO.puts("FV_INSTANCE_IDS=#{running.id},#{sleeping.id},#{stopped.id},#{hidden_instance.id}")

# Dev-only capture setup for the operator storage-request queue (#250).
# RESETS its own prior rows (slug prefix storage-capture-), then builds
# one deterministic state: a funded org with three running instances,
# two open storage requests from a member, and a third instance held for
# the live-insert GIF. Prints the admin session token, the member PAT,
# and the live-insert instance id.
#
# Run from apps/platform: mix run ../e2e/admin_storage_requests_seed.exs

alias FluxVale.Accounts.Membership
alias FluxVale.Accounts.Organization
alias FluxVale.Billing
alias FluxVale.Catalog.App
alias FluxVale.Catalog.AppVersion
alias FluxVale.Catalog.Category
alias FluxVale.Identity.User
alias FluxVale.Infrastructure.Cluster
alias FluxVale.Infrastructure.Instance
alias FluxVale.Infrastructure.Operations.InstanceK8s
alias FluxVale.Infrastructure.StorageRequest
alias FluxVale.Pricing.Size

import Ecto.Query
alias FluxVale.Repo

# Reset this script's full capture subject. FK order: requests,
# hostnames, instances, ledger entries, wallets, memberships, orgs
# (the ledger is append-only, so the capture reset rides the data layer
# directly — dev-capture tooling, not a product path).
org_ids =
  Repo.all(from(o in "organizations", where: like(o.slug, "storage-capture-%"), select: o.id))

instance_ids =
  Repo.all(from(i in "instances", where: i.organization_id in ^org_ids, select: i.id))

wallet_ids =
  Repo.all(from(w in "billing_wallets", where: w.organization_id in ^org_ids, select: w.id))

Repo.delete_all(from(r in "storage_requests", where: r.organization_id in ^org_ids))
Repo.delete_all(from(h in "instance_hostnames", where: h.instance_id in ^instance_ids))
Repo.delete_all(from(i in "instances", where: i.id in ^instance_ids))

{_, nil} =
  Repo.delete_all(from(e in "billing_ledger_entries", where: e.wallet_id in ^wallet_ids))

{_, nil} = Repo.delete_all(from(w in "billing_wallets", where: w.id in ^wallet_ids))
{_, nil} = Repo.delete_all(from(m in "memberships", where: m.organization_id in ^org_ids))

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

# The seed admin (seeds.exs creates it; get-or-create keeps this script
# safe on a fresh dev DB).
admin =
  case User.get_by_email("admin@fluxvale.com", authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      User
      |> Ash.Changeset.for_create(:create, %{email: "admin@fluxvale.com", platform_role: :admin})
      |> Ash.create!(authorize?: false)
  end

# ResolveCluster pins THE single cluster row — the setup's local_seeds
# created it; get-or-create keeps this script safe on a fresh dev DB.
case Ash.read!(Cluster, authorize?: false) do
  [] -> Cluster.create!(%{name: "local"}, authorize?: false)
  [cluster] -> cluster
  _multiple -> raise "multiple cluster rows — ResolveCluster requires exactly one"
end

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
n = :erlang.unique_integer([:positive])

category =
  Category.create!(
    %{name: "Capture #{n}", slug: "storage-capture-#{n}", description: "capture fixture"},
    authorize?: false
  )

app =
  App.create!(
    %{
      name: "Knowledge Base #{suffix}",
      slug: "knowledge-base-#{n}",
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
      slug: "storage-capture-#{n}",
      cpu_cores: Decimal.new("0.5"),
      memory_mb: 512,
      monthly_cents: 240
    },
    authorize?: false
  )

version =
  AppVersion.create!(
    %{
      version: "1.4.#{rem(n, 100)}",
      image: "registry.example.com/kb:1.4",
      port: 3000,
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 512,
      default_storage_gb: 10,
      app_id: app.id,
      recommended_size_id: size.id
    },
    authorize?: false
  )

org =
  Organization.create!(
    %{name: "Northwind Labs", slug: "storage-capture-#{suffix}"},
    authorize?: false
  )

{:ok, wallet} = Billing.ensure_wallet(org)
{:ok, _fund} = Billing.grant_credits(wallet, 25_000, reason: :adjustment)

Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
  authorize?: false
)

member =
  User.create!("dana.storage-capture-#{suffix}@fluxvale.test", %{}, authorize?: false)

Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
  authorize?: false
)

instance! = fn name ->
  instance =
    Instance.create!(
      %{name: name, app_version_id: version.id, organization_id: org.id},
      actor: admin
    )

  {:ok, instance} = InstanceK8s.update_status(instance, :deploying, nil)
  {:ok, instance} = InstanceK8s.update_status(instance, :starting, nil)
  {:ok, instance} = InstanceK8s.update_status(instance, :running, nil)
  instance
end

archive = instance!.("Archive Hub")
video = instance!.("Video Bay")
live = instance!.("Cold Storage")

request! = fn instance, requested_gb, reason ->
  StorageRequest
  |> Ash.Changeset.for_create(
    :request,
    %{instance_id: instance.id, requested_gb: requested_gb, reason: reason},
    actor: member
  )
  |> Ash.create!()
end

_request_a = request!.(archive, 200, "Archive vault growth")
_request_b = request!.(video, 150, "Video exports")

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

{:ok, %{token: pat}} =
  FluxVale.Identity.mint_pat(admin, %{
    user_id: member.id,
    name: "storage-capture",
    scopes: ["instances:read", "instances:write"]
  })

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_PAT=#{pat}")
IO.puts("FV_LIVE_INSTANCE_ID=#{live.id}")

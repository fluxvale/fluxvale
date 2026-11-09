# Dev-only capture setup for the cross-org console slice (#644, A1-S2).
# RESETS its own prior rows (the %-capture-% sweep the orgs seed owns —
# every lane's leftovers read as live orgs in the list), then builds
# one shape-deterministic state:
#
# - "Northwind Labs" (MEMBER org): an active gateway carrying all of
#   #613's operator-truth fields (attention-free state, a stamped API
#   key, two tailnet claims) — the detail capture — plus two instances
#   (running / sleeping) whose creates minted the platform domain row,
#   and a pending + a verified custom domain — the member org-detail
#   capture with its domains card.
# - "Ferrostamp Co" (MEMBER org): a needs_attention gateway anchored
#   three days back — the attention clock on the index and the
#   attention detail.
# - "Harborworks" (NON-member org): an active gateway the admin does
#   NOT belong to (cross-org row on camera) and one instance whose
#   create minted the platform domain — the stranger org-detail
#   capture: instances and domains of an org the admin is not inside.
# - Two invitations (one pending, one accepted by its JIT owner) — the
#   people list, whose accepted row belongs to a foreign org.
#
# The gateway rows ride Ash.Seed.seed! (not the create action): the
# create's cluster leg provisions against Tailscale/K8s, which
# dev-capture tooling has none of — the documented seed! exception.
# Everything that CAN move through actions does: the states ride the
# :update_state funnel, the API-token ref and claims ride their system
# funnels, the platform domains ride the real instance creates, and
# the invitations ride the real invite operation.
#
# Prints the admin session token and every id the capture script
# needs.
#
# Run from apps/platform: mix run ../e2e/admin_crossorg_seed.exs

alias FluxVale.Accounts.Membership
alias FluxVale.Accounts.Organization
alias FluxVale.Billing
alias FluxVale.Catalog.App
alias FluxVale.Catalog.AppVersion
alias FluxVale.Catalog.Category
alias FluxVale.Identity
alias FluxVale.Identity.User
alias FluxVale.Infrastructure.AccessDomain
alias FluxVale.Infrastructure.AccessGateway
alias FluxVale.Infrastructure.Cluster
alias FluxVale.Infrastructure.Instance
alias FluxVale.Infrastructure.Operations.InstanceK8s
alias FluxVale.Pricing.Size

alias FluxVale.Repo

import Ecto.Query

# The orgs seed's full capture sweep: every capture-prefixed org across
# lanes (the orgs list shows every org with a wallet, so leftovers of
# ANY lane read as live data). FK order: hostnames, instances, ledger,
# wallets, memberships, routes, gateways, domains, orgs — the ledger is
# append-only, so the reset rides the data layer directly
# (dev-capture tooling, not a product path).
org_ids =
  Repo.all(from(o in "organizations", where: like(o.slug, "%-capture-%"), select: o.id))

instance_ids =
  Repo.all(from(i in "instances", where: i.organization_id in ^org_ids, select: i.id))

wallet_ids =
  Repo.all(from(w in "billing_wallets", where: w.organization_id in ^org_ids, select: w.id))

gateway_ids =
  Repo.all(from(g in "access_gateways", where: g.organization_id in ^org_ids, select: g.id))

{_, nil} = Repo.delete_all(from(h in "instance_hostnames", where: h.instance_id in ^instance_ids))
{_, nil} = Repo.delete_all(from(i in "instances", where: i.id in ^instance_ids))

{_, nil} =
  Repo.delete_all(from(e in "billing_ledger_entries", where: e.wallet_id in ^wallet_ids))

{_, nil} = Repo.delete_all(from(w in "billing_wallets", where: w.id in ^wallet_ids))
{_, nil} = Repo.delete_all(from(m in "memberships", where: m.organization_id in ^org_ids))
{_, nil} = Repo.delete_all(from(r in "access_routes", where: r.gateway_id in ^gateway_ids))
{_, nil} = Repo.delete_all(from(g in "access_gateways", where: g.id in ^gateway_ids))
{_, nil} = Repo.delete_all(from(d in "access_domains", where: d.organization_id in ^org_ids))
{_, nil} = Repo.delete_all(from(o in "organizations", where: o.id in ^org_ids))

# The seed admin (seeds.exs creates it at bin/seed; get-or-create keeps
# this script safe on a fresh dev DB).
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

# ResolveCluster pins THE single cluster row (the setup's local_seeds
# created it; get-or-create keeps this script safe on a fresh dev DB).
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
      %{name: name, slug: "crossorg-capture-#{suffix}-#{System.unique_integer([:positive])}"},
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

# The instance fixtures' dev shape (the orgs seed's): category → app →
# size → version, through actions.
version! = fn ->
  n = System.unique_integer([:positive])

  category =
    Category.create!(
      %{name: "CrossOrg #{n}", slug: "crossorg-#{n}", description: "capture fixture"},
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
      %{slug: "crossorg-#{n}", cpu_cores: Decimal.new("0.5"), memory_mb: 256, monthly_cents: 100},
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

# The gateway rows ride seed! (the create's cluster leg has no cluster
# to satisfy — the documented exception), then the funnels own state.
gateway! = fn org, opts ->
  hostname = "fv-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  gateway =
    Ash.Seed.seed!(AccessGateway, %{
      organization_id: org.id,
      hostname: hostname,
      tailnet_domain: Keyword.get(opts, :tailnet_domain, "capture.ts.net"),
      provider: :tailscale,
      state: :provisioning,
      status_message: Keyword.get(opts, :status_message),
      monthly_cents: 200,
      credential_secret_ref: "gateway-credential-#{suffix}",
      provisioned_at: Keyword.get(opts, :provisioned_at)
    })

  state = Keyword.get(opts, :state, :provisioning)

  if state == :provisioning do
    gateway
  else
    Ash.update!(
      gateway,
      %{
        state: state,
        metering_since: if(state == :active, do: DateTime.utc_now(), else: nil),
        needs_attention_since:
          if(state == :needs_attention, do: DateTime.add(DateTime.utc_now(), -3, :day), else: nil)
      },
      action: :update_state,
      authorize?: false
    )
  end
end

# 1. The member detail subject: Northwind Labs — an active gateway
#    carrying the full #613 vocabulary, two instances whose creates
#    minted the platform domain, and two custom domains.
{detail_org, detail_wallet} = org!.("Northwind Labs")
{:ok, _fund} = Billing.grant_credits(detail_wallet, 6_000, reason: :adjustment)
member!.(detail_org)

detail_version = version!()

instance! = fn name ->
  Instance.create!(
    %{name: name, app_version_id: detail_version.id, organization_id: detail_org.id},
    actor: admin
  )
end

running = instance!.("Team Wiki")
sleeping = instance!.("Archive Wiki")

{:ok, running} = InstanceK8s.update_status(running, :deploying, nil)
{:ok, running} = InstanceK8s.update_status(running, :starting, nil)
{:ok, running} = InstanceK8s.update_status(running, :running, nil)

{:ok, sleeping} = InstanceK8s.update_status(sleeping, :deploying, nil)
{:ok, sleeping} = InstanceK8s.update_status(sleeping, :starting, nil)
{:ok, sleeping} = InstanceK8s.update_status(sleeping, :running, nil)
{:ok, sleeping} = InstanceK8s.update_status(sleeping, :sleeping, nil)

detail_gateway =
  gateway!.(detail_org,
    state: :active,
    tailnet_domain: "northwind.ts.net",
    status_message: "Connected",
    provisioned_at: DateTime.utc_now()
  )

# The API-token ref and its rotation stamp, then the tailnet claims —
# both through their system funnels (the claim operation's map shape).
# One claimed name matches the verified custom row (issuance and
# resolution agree), the other matches nothing (a claim the cert table
# does not mirror — the two vocabularies stay distinct).
detailed =
  AccessGateway.set_api_token_ref!(
    detail_gateway,
    %{api_token_secret_ref: "gateway-api-token-#{suffix}"},
    authorize?: false
  )

detailed =
  AccessGateway.update_claims!(
    detailed,
    %{
      dns_claims: %{
        "apps.quillsystems.test" => %{
          "ip" => "100.100.100.100",
          "tailnet" => "northwind.ts.net"
        },
        "alpha.apps.northwind.test" => %{
          "ip" => "100.100.100.100",
          "tailnet" => "northwind.ts.net"
        }
      }
    },
    authorize?: false
  )

# The custom domains: rows through seed! (the :register action mints a
# wildcard Certificate in the cluster inside its transaction), then the
# verified one through its funnel.
custom_pending =
  Ash.Seed.seed!(AccessDomain, %{
    domain: "apps.lanternmill.test",
    kind: :custom,
    state: :pending,
    organization_id: detail_org.id
  })

custom_verified =
  Ash.Seed.seed!(AccessDomain, %{
    domain: "apps.quillsystems.test",
    kind: :custom,
    state: :pending,
    organization_id: detail_org.id
  })

custom_verified =
  Ash.update!(
    custom_verified,
    %{cert_secret_ref: "access-domain-#{suffix}"},
    action: :mark_verified,
    authorize?: false
  )

# 2. The attention subject: Ferrostamp Co — needs attention for three
#    days, the clock's anchor the funnels wrote.
{attention_org, _attention_wallet} = org!.("Ferrostamp Co")
member!.(attention_org)

attention_gateway =
  gateway!.(attention_org,
    state: :needs_attention,
    status_message: "We can't reach your gateway. Paste a fresh key to reconnect.",
    provisioned_at: DateTime.utc_now()
  )

# 3. The stranger subject: Harborworks — an active gateway and one
#    instance (its create minted the platform domain) in an org the
#    admin is NOT a member of: the cross-org row, and the cross-org
#    org detail.
{stranger_org, stranger_wallet} = org!.("Harborworks")
{:ok, _fund} = Billing.grant_credits(stranger_wallet, 10_000, reason: :adjustment)

stranger =
  User.create!(
    "crossorg-capture-stranger-#{System.unique_integer([:positive])}@fluxvale.test",
    %{},
    authorize?: false
  )

Membership.create!(%{organization_id: stranger_org.id, user_id: stranger.id, role: :owner},
  authorize?: false
)

stranger_gateway =
  gateway!.(stranger_org,
    state: :active,
    tailnet_domain: "harborworks.ts.net",
    status_message: "Connected",
    provisioned_at: DateTime.utc_now()
  )

stranger_instance =
  Instance.create!(
    %{name: "Their Wiki", app_version_id: detail_version.id, organization_id: stranger_org.id},
    actor: stranger
  )

{:ok, stranger_instance} = InstanceK8s.update_status(stranger_instance, :deploying, nil)
{:ok, stranger_instance} = InstanceK8s.update_status(stranger_instance, :starting, nil)
{:ok, stranger_instance} = InstanceK8s.update_status(stranger_instance, :running, nil)

# 4. The people rows: one pending invitation, one accepted by its
#    owner (whose acceptance JIT-provisions their own foreign org).
{:ok, pending_invitee, _pending_raw} =
  Identity.invite_user(admin, "crossorg-pending-#{suffix}@fluxvale.test")

{:ok, accepted_invitee, accepted_raw} =
  Identity.invite_user(admin, "crossorg-accepted-#{suffix}@fluxvale.test")

{:ok, _accepted_user, _jwt} = Identity.accept_invitation(accepted_raw)

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_GATEWAY_DETAIL=#{detailed.id}")
IO.puts("FV_GATEWAY_ATTENTION=#{attention_gateway.id}")
IO.puts("FV_ORG_DETAIL=#{detail_org.id}")
IO.puts("FV_ORG_DETAIL_STRANGER=#{stranger_org.id}")
IO.puts("FV_GATEWAY_STRANGER=#{stranger_gateway.id}")
IO.puts("FV_PEOPLE_PENDING=#{pending_invitee.id}")
IO.puts("FV_PEOPLE_ACCEPTED=#{accepted_invitee.id}")
IO.puts("FV_DOMAIN_PENDING=#{custom_pending.id}")
IO.puts("FV_DOMAIN_VERIFIED=#{custom_verified.id}")

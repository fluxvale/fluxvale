# Dev-only capture setup for the admin gateways surface (#501, #613).
# RESETS its own prior rows (slug prefix gateways-capture-), then builds
# one SHAPE-DETERMINISTIC state (the same orgs, gateways, and states
# every run; names carry a random suffix) — the capture admin is a
# MEMBER of six gateway orgs (one gateway per org — the resource's
# unique_organization identity): five covering every gateway state the
# product defines (provisioning / active / needs_attention / suspended /
# destroying), plus the domains-empty quiet org; a member org with the
# detail capture's domains (platform verified + custom pending /
# verified / failed / needs_attention / suspended, one of them CLAIMED
# on the tailnet), and a NON-member org whose active gateway the list
# now RENDERS — #613's cross-org arm on camera.
#
# The gateway rows ride Ash.Seed.seed! (not the create action): the create's
# cluster leg provisions against Tailscale/K8s, which dev-capture
# tooling has none of — the documented seed! exception. Everything that
# CAN move through actions does: the states ride the :update_state
# funnel, the platform domain rides :mint_platform, and the custom
# domains' non-pending states ride the mark_* funnels.
#
# Prints the capture admin's session token and every id the capture
# script needs.
#
# Run from apps/platform: mix run ../e2e/admin_gateways_seed.exs

alias FluxVale.Accounts.Membership
alias FluxVale.Accounts.Organization
alias FluxVale.Identity.User
alias FluxVale.Infrastructure.AccessDomain
alias FluxVale.Infrastructure.AccessGateway
alias FluxVale.Repo

import Ecto.Query

# Reset this script's own prior rows (the dev DB keeps everything
# else). FK order: gateways and domains restrict on their org, so the
# orgs go last (dev-capture tooling, not a product path — the ledger is
# append-only and the wallet reset rides the data layer directly, the
# orgs capture seed's stance).
org_ids =
  Repo.all(from(o in "organizations", where: like(o.slug, "gateways-capture-%"), select: o.id))

gateway_ids =
  Repo.all(from(g in "access_gateways", where: g.organization_id in ^org_ids, select: g.id))

wallet_ids =
  Repo.all(from(w in "billing_wallets", where: w.organization_id in ^org_ids, select: w.id))

{_, nil} = Repo.delete_all(from(g in "access_gateways", where: g.id in ^gateway_ids))

{_, nil} =
  Repo.delete_all(from(d in "access_domains", where: d.organization_id in ^org_ids))

{_, nil} = Repo.delete_all(from(e in "billing_ledger_entries", where: e.wallet_id in ^wallet_ids))

{_, nil} = Repo.delete_all(from(w in "billing_wallets", where: w.id in ^wallet_ids))

{_, nil} = Repo.delete_all(from(m in "memberships", where: m.organization_id in ^org_ids))

{_, nil} = Repo.delete_all(from(o in "organizations", where: o.id in ^org_ids))

# The org-less capture admin's rows are no longer built (the scope
# note is gone with #613's arm — an org-less admin sees the same
# cross-org list); stale rows from a prior run are still swept here so
# the dev DB doesn't accumulate them. The users sweep keys on username
# — the table carries no email column since the user_emails move
# (#285), and the mirror sweep rides the address as before.
{_, nil} =
  Repo.delete_all(from(ue in "user_emails", where: like(ue.address, "gateways-orgless-capture%")))

{_, nil} =
  Repo.delete_all(from(u in "users", where: u.username == "gateways-orgless-capture"))

# The seed admin (seeds.exs creates it at bin/seed; get-or-create keeps
# this script safe on a fresh dev DB). The empty-state capture session
# is gone: with #613's cross-org read, a populated dev DB renders every
# seeded gateway for ANY admin, so no seeded account can produce the
# global empty on camera (the live tests pin it).
admin =
  case User.get_by_email("admin@fluxvale.com", authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
  end

suffix = Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

org! = fn name ->
  Organization.create!(
    %{
      name: name,
      slug: "gateways-capture-#{suffix}-#{System.unique_integer([:positive])}"
    },
    authorize?: false
  )
end

member! = fn org ->
  Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
    authorize?: false
  )
end

# Ash.Seed.seed! — the create action's synchronous cluster leg (ProvisionCluster
# through the Tailscale provider) cannot run in dev-capture tooling (no
# cluster, no kubeconfig), so no action path can produce the row here
# (the documented seed! exception). The state funnel takes it from here.
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
        needs_attention_since: if(state == :needs_attention, do: DateTime.utc_now(), else: nil)
      },
      action: :update_state,
      authorize?: false
    )
  end
end

# The capture detail: an active gateway on the first member org, with
# the domains card's full vocabulary around it.
detail_org = org!.("Northwind Labs")
member!.(detail_org)

detail_gateway =
  gateway!.(detail_org,
    state: :active,
    tailnet_domain: "northwind.ts.net",
    status_message: "Connected",
    provisioned_at: DateTime.utc_now()
  )

# Ash.Seed.seed! for the platform row? No — :mint_platform is a pure write,
# callable through the system seam. The org's platform domain, born
# :verified.
AccessDomain.mint_platform!(
  %{domain: "fluxvale.lvh.me", organization_id: detail_org.id},
  authorize?: false
)

# The custom domains: rows through Ash.Seed.seed! (the :register action mints
# a wildcard Certificate in the cluster inside its transaction — no
# cluster in dev-capture tooling), then every non-pending state through
# its funnel. :needs_attention is only honest after :verified observed
# Ready once, so it rides both funnels.
pending_domain =
  Ash.Seed.seed!(AccessDomain, %{
    domain: "apps.quillsystems.com",
    kind: :custom,
    state: :pending,
    organization_id: detail_org.id
  })

verified_row =
  Ash.Seed.seed!(AccessDomain, %{
    domain: "apps.harborworks.com",
    kind: :custom,
    state: :pending,
    organization_id: detail_org.id
  })

verified_domain =
  Ash.update!(
    verified_row,
    %{cert_secret_ref: "access-domain-#{suffix}"},
    action: :mark_verified,
    authorize?: false
  )

failed_row =
  Ash.Seed.seed!(AccessDomain, %{
    domain: "apps.ferrostamp.com",
    kind: :custom,
    state: :pending,
    organization_id: detail_org.id
  })

failed_domain = Ash.update!(failed_row, %{}, action: :mark_failed, authorize?: false)

attention_row =
  Ash.Seed.seed!(AccessDomain, %{
    domain: "apps.lanternmill.com",
    kind: :custom,
    state: :pending,
    organization_id: detail_org.id
  })

attention_verified =
  Ash.update!(
    attention_row,
    %{cert_secret_ref: "access-domain-#{suffix}b"},
    action: :mark_verified,
    authorize?: false
  )

attention_domain =
  Ash.update!(attention_verified, %{}, action: :mark_needs_attention, authorize?: false)

# The fifth domain state: :suspended rides Ash.Seed.seed! — the
# mark_suspended funnel is fail-closed on its cluster legs (the unclaim
# limb, the edge-route removal), which dev-capture tooling has no
# cluster to satisfy, so no action path can produce the row here (the
# documented seed! exception; the legacy-resume shape is what this
# state renders).
suspended_domain =
  Ash.Seed.seed!(AccessDomain, %{
    domain: "apps.stonemarch.com",
    kind: :custom,
    state: :suspended,
    organization_id: detail_org.id
  })

# #613's operator-truth columns, through their system funnels (the only
# writers): the API token ref (which stamps token_set_at — the 90-day
# key-age line) and the tailnet claims map (the verified custom domain
# and the platform row claimed; the rest unclaimed — the contrast the
# domains table now renders). The token ref write is what stamps
# token_set_at, so the key-age line has its fact.
AccessGateway.set_api_token_ref!(
  detail_gateway,
  %{api_token_secret_ref: "gateway-api-token-#{suffix}"},
  authorize?: false
)

detail_gateway
|> Ash.Changeset.for_update(
  :update_claims,
  %{
    dns_claims: %{
      "apps.harborworks.com" => %{"ip" => "100.100.100.1", "tailnet" => "northwind.ts.net"},
      "fluxvale.lvh.me" => %{"ip" => "100.100.100.1", "tailnet" => "northwind.ts.net"}
    }
  },
  authorize?: false
)
|> Ash.update!()

# The other four member orgs: one gateway per remaining state.
provisioning_org = org!.("Beacon Works")
member!.(provisioning_org)
gateway!.(provisioning_org, state: :provisioning)

attention_org = org!.("Ferrostamp Co")
member!.(attention_org)

attention_gateway =
  gateway!.(attention_org,
    state: :needs_attention,
    status_message: "We can't reach your gateway. Paste a fresh key to reconnect.",
    provisioned_at: DateTime.utc_now()
  )

suspended_org = org!.("Harborworks")
member!.(suspended_org)
gateway!.(suspended_org, state: :suspended, status_message: "Suspended. The balance ran out.")

destroying_org = org!.("Lanternmill")
member!.(destroying_org)
gateway!.(destroying_org, state: :destroying, status_message: "Removing access")

# The domains-empty detail subject: a member org whose gateway runs,
# whose org holds no domain rows (the detail's honest empty).
quiet_org = org!.("Quiet Org")
member!.(quiet_org)
quiet_gateway = gateway!.(quiet_org, state: :active, status_message: "Connected")

# The non-member org: its gateway exists and is healthy, and with
# #613's arm the list RENDERS it — the cross-org read on camera.
stranger_org = org!.("Stranger Org")

stranger =
  User.create!(
    "gateways-capture-stranger-#{System.unique_integer([:positive])}@fluxvale.test",
    %{},
    authorize?: false
  )

Membership.create!(%{organization_id: stranger_org.id, user_id: stranger.id, role: :owner},
  authorize?: false
)

crossorg_gateway = gateway!.(stranger_org, state: :active, status_message: "Connected")

# Stale rows from the pre-#613 seed (the gateway-less empty admin and
# the org-less scope-note admin) are swept too — their capture sessions
# no longer exist. The empty admin's membership rows go before its user
# row (FK order); both users are found by username — the table carries
# no email column since the user_emails move (#285), the mirrors by
# address. The empty admin's JIT personal org stays orphaned (dev
# capture tooling, no product path reads it).
{_, nil} =
  Repo.delete_all(from(ue in "user_emails", where: like(ue.address, "gateways-empty-capture%")))

stale_user_ids =
  Repo.all(from(u in "users", where: u.username == "gateways-empty-capture", select: u.id))

{_, nil} = Repo.delete_all(from(m in "memberships", where: m.user_id in ^stale_user_ids))

{_, nil} =
  Repo.delete_all(
    from(u in "users",
      where: u.username in ^["gateways-empty-capture", "gateways-orgless-capture"]
    )
  )

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_GATEWAY_DETAIL=#{detail_gateway.id}")
IO.puts("FV_GATEWAY_ATTENTION=#{attention_gateway.id}")
IO.puts("FV_GATEWAY_NODOMAINS=#{quiet_gateway.id}")
IO.puts("FV_GATEWAY_CROSSORG=#{crossorg_gateway.id}")

IO.puts(
  "FV_DOMAINS=#{pending_domain.id},#{verified_domain.id},#{failed_domain.id},#{attention_domain.id},#{suspended_domain.id}"
)

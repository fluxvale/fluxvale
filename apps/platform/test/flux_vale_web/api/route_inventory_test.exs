defmodule FluxValeWeb.Api.RouteInventoryTest do
  @moduledoc false

  # #360: the router's route set IS the contract — enumerate it
  # (AshJsonApi.Router.formatted_routes, the same mechanism
  # `mix phx.routes` rides) and assert the exact table from the issue:
  # every {method, path} exists, and no system-only action has a route.

  use FluxValeWeb.ConnCase, async: true

  alias AshJsonApi.Router

  # The contract, first cut (#360's table). GET /me rides Identity
  # (slice 0). The scope column lives with the PAT slice; here the
  # paths are the assertion.
  @expected [
    {:get, "/me"},
    # The actor's own orgs (#362 T6a) — scopeless like /me.
    {:get, "/organizations"},
    # instances:read / instances:write
    {:get, "/instances"},
    {:post, "/instances"},
    {:get, "/instances/:id"},
    # #731 T2: the slug lookup (an extra segment — cannot collide with
    # /instances/:id).
    {:get, "/instances/by-slug/:slug"},
    {:patch, "/instances/:id/deploy"},
    {:patch, "/instances/:id/stop"},
    {:patch, "/instances/:id/start"},
    {:patch, "/instances/:id/always-on"},
    {:patch, "/instances/:id/exposure"},
    # #493: the stopped-first resize.
    {:patch, "/instances/:id/resize"},
    # #731 T1: the in-place env merge.
    {:patch, "/instances/:id/env"},
    # #250: the member storage-request verbs (operator decisions stay
    # web-only — no admin scope).
    {:post, "/instances/:instance_id/storage-requests"},
    {:get, "/instances/:instance_id/storage-requests"},
    {:get, "/storage-requests/:id"},
    {:delete, "/instances/:id"},
    # #597 S4: the PocketID wiring verb.
    {:post, "/instances/:id/connect-pocketid"},
    # #731 T3: the wiring's disconnect/rotate + the provider's read.
    {:post, "/instances/:id/disconnect-pocketid"},
    {:post, "/instances/:id/rotate-pocketid-secret"},
    {:get, "/instances/:instance_id/pocket-id-wiring"},
    # S6 (#751): the member custom-address verbs.
    {:post, "/instances/:instance_id/hostnames"},
    {:get, "/instances/:instance_id/hostnames"},
    {:delete, "/instance-hostnames/:id"},
    # backups:read / backups:write
    {:get, "/instances/:instance_id/backup-setting"},
    {:post, "/instances/:instance_id/backup-setting"},
    {:get, "/instances/:instance_id/backup-runs"},
    {:post, "/instances/:id/backup-runs"},
    {:post, "/instances/:id/backup-runs/:backup_run_id/restore"},
    {:patch, "/backup-settings/:id"},
    {:delete, "/backup-settings/:id"},
    # gateways:read / gateways:write
    {:get, "/organizations/:organization_id/access-gateway"},
    {:post, "/access-gateways"},
    {:patch, "/access-gateways/:id/resume"},
    {:post, "/access-gateways/:gateway_id/attachments"},
    {:delete, "/access-gateways/:gateway_id/attachments/:instance_id"},
    # gateways:read / gateways:write — the access domains (#482)
    {:post, "/access-domains"},
    {:get, "/organizations/:organization_id/access-domains"},
    {:get, "/access-domains/:id"},
    {:patch, "/access-domains/:id/resume"},
    {:delete, "/access-domains/:id"},
    # wallet:read
    {:get, "/organizations/:organization_id/wallet"},
    {:get, "/organizations/:organization_id/wallet/runway"},
    {:get, "/wallets/:wallet_id/ledger-entries"},
    # catalog:read
    {:get, "/apps"},
    {:get, "/apps/:slug"},
    {:get, "/apps/:app_id/versions"},
    {:get, "/app-versions/:id"}
  ]

  # {resource, action} pairs that may NEVER grow a route: the
  # system-only funnels (actorless by design) and the wallet/ledger
  # writes (read-only over the API, per the scope table).
  @unroutable [
    # Instance's platform-only writes
    {FluxVale.Infrastructure.Instance, :sleep},
    {FluxVale.Infrastructure.Instance, :touch},
    {FluxVale.Infrastructure.Instance, :settle_anchors},
    {FluxVale.Infrastructure.Instance, :update_status},
    {FluxVale.Infrastructure.Instance, :perform_deploy},
    {FluxVale.Infrastructure.Instance, :perform_reconcile},
    {FluxVale.Infrastructure.Instance, :perform_settle},
    {FluxVale.Infrastructure.Instance, :perform_teardown},
    {FluxVale.Infrastructure.Instance, :mark_deploy_error},
    {FluxVale.Infrastructure.Instance, :mark_teardown_error},
    # The gateway's platform-only writes
    {FluxVale.Infrastructure.AccessGateway, :suspend},
    {FluxVale.Infrastructure.AccessGateway, :update_state},
    {FluxVale.Infrastructure.AccessGateway, :set_api_token_ref},
    {FluxVale.Infrastructure.AccessGateway, :update_claims},
    {FluxVale.Infrastructure.AccessGateway, :perform_provision},
    {FluxVale.Infrastructure.AccessGateway, :perform_settle},
    {FluxVale.Infrastructure.AccessGateway, :perform_observe},
    {FluxVale.Infrastructure.AccessGateway, :perform_teardown},
    {FluxVale.Infrastructure.AccessGateway, :mark_provision_error},
    {FluxVale.Infrastructure.AccessGateway, :mark_teardown_error},
    {FluxVale.Infrastructure.AccessGateway, :destroy_after_teardown},
    # The access domain's system-only writes (#482: the routed surface
    # is register/list_for_org/get_by_id/resume/remove_via_api — the
    # raw :remove destroy stays the operation's own row-level step)
    {FluxVale.Infrastructure.AccessDomain, :mint_platform},
    {FluxVale.Infrastructure.AccessDomain, :list_all},
    {FluxVale.Infrastructure.AccessDomain, :remove},
    {FluxVale.Infrastructure.AccessDomain, :mark_verified},
    {FluxVale.Infrastructure.AccessDomain, :mark_failed},
    {FluxVale.Infrastructure.AccessDomain, :mark_needs_attention},
    {FluxVale.Infrastructure.AccessDomain, :mark_suspended},
    # The storage-request workflow's operator/system writes (#250) —
    # approve/reject/retry are the web queue's, mark_* the apply's, and
    # the queue read is admin-only.
    {FluxVale.Infrastructure.StorageRequest, :queue},
    {FluxVale.Infrastructure.StorageRequest, :approve},
    {FluxVale.Infrastructure.StorageRequest, :reject},
    {FluxVale.Infrastructure.StorageRequest, :retry_apply},
    {FluxVale.Infrastructure.StorageRequest, :mark_applied},
    {FluxVale.Infrastructure.StorageRequest, :mark_apply_failed},
    # The money machinery is system-only; the API reads the wallet
    {FluxVale.Billing.Wallet, :create},
    {FluxVale.Billing.Wallet, :set_carryover},
    {FluxVale.Billing.Wallet, :set_ladder_state},
    {FluxVale.Billing.Wallet, :set_waiver},
    {FluxVale.Billing.LedgerEntry, :create},
    {FluxVale.Billing.LedgerEntry, :grant_goodwill}
  ]

  defp inventory do
    routes = Router.formatted_routes(FluxValeWeb.AshJsonApiRouter)

    MapSet.new(routes, &{&1.verb, &1.path})
  end

  defp routed_labels do
    routes = Router.formatted_routes(FluxValeWeb.AshJsonApiRouter)

    Enum.map(routes, & &1.label)
  end

  test "the route set matches the contract table exactly" do
    expected = MapSet.new(@expected)

    assert inventory() == expected
  end

  test "no system-only action carries a route" do
    # The label is "<router> <resource>.<action>" — match on the
    # dotted suffix (no runtime atom creation), so a legit member
    # action (BackupSetting's :create) never trips the money
    # machinery's :create. No separator before the resource: the
    # label's is a space, and a leading dot here would make every
    # ends_with? miss — a vacuous assertion.
    unroutable_suffixes =
      MapSet.new(@unroutable, fn {resource, action} ->
        inspect(resource) <> "." <> Atom.to_string(action)
      end)

    leaks =
      Enum.filter(routed_labels(), fn label ->
        Enum.any?(unroutable_suffixes, &String.ends_with?(label, &1))
      end)

    assert leaks == []

    # The mechanism itself: a ROUTED action's label must not match any
    # unroutable suffix (guards against a separator change re-vacuating
    # the assertion above).
    routed_label = Enum.find(routed_labels(), &String.ends_with?(&1, "Instance.deploy"))

    assert routed_label
    refute Enum.any?(unroutable_suffixes, &String.ends_with?(routed_label, &1))
  end
end

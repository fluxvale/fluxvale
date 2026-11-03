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
    # instances:read / instances:write
    {:get, "/instances"},
    {:get, "/instances/:id"},
    {:patch, "/instances/:id/deploy"},
    {:patch, "/instances/:id/stop"},
    {:patch, "/instances/:id/start"},
    {:patch, "/instances/:id/always-on"},
    {:patch, "/instances/:id/exposure"},
    {:delete, "/instances/:id"},
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
    # machinery's :create.
    unroutable_suffixes =
      MapSet.new(@unroutable, fn {resource, action} ->
        "." <> inspect(resource) <> "." <> Atom.to_string(action)
      end)

    leaks =
      Enum.filter(routed_labels(), fn label ->
        Enum.any?(unroutable_suffixes, &String.ends_with?(label, &1))
      end)

    assert leaks == []
  end
end

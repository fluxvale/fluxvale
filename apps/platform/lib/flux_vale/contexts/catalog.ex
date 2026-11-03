defmodule FluxVale.Catalog do
  @moduledoc """
  Catalog: the apps FluxVale one-click-deploys — Category/App/AppVersion
  (#70, port of v1's domain per docs/v1-salvage.md). Reads are public
  (#164, ADR-00025 — the catalog is a marketing surface); mutation is
  platform-admin-only. Opts into AshAdmin (ADR-0027): the dashboard rides
  the same policies, no new auth model — dev-only routes, route-gated
  away from prod.
  """

  # AshJsonApi.Domain (#360): the resource-level json_api blocks ride
  # the domain through AshJsonApiRouter — routes are contract
  # (ADR-0019 §1).
  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain, AshJsonApi.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(FluxVale.Catalog.Category)
    resource(FluxVale.Catalog.App)
    resource(FluxVale.Catalog.AppVersion)
  end
end

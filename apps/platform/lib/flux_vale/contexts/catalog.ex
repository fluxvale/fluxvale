defmodule FluxVale.Catalog do
  @moduledoc """
  Catalog: the apps FluxVale one-click-deploys — Category/App/AppVersion
  (#70, port of v1's domain per docs/v1-salvage.md). Reads are any signed-in
  actor (the M3 deploy flow #74 browses it; public read relaxes with M7
  catalog pages); mutation is platform-admin-only. Opts into AshAdmin
  (ADR-0027): the dashboard rides the same policies, no new auth model.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource FluxVale.Catalog.Category
    resource FluxVale.Catalog.App
    resource FluxVale.Catalog.AppVersion
  end
end

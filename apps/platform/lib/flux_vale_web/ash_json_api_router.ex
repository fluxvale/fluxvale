defmodule FluxValeWeb.AshJsonApiRouter do
  @moduledoc """
  JSON:API surface — first-class and day-one (ADR-0019). Mounted at
  `/api/v1` (#24 settles OQ #9 on URL-prefix versioning; the OpenAPI
  endpoint at `/api/v1/open_api` feeds CLI/client generation later).
  """

  use AshJsonApi.Router,
    domains: [
      FluxVale.Identity,
      FluxVale.Infrastructure,
      FluxVale.Billing,
      FluxVale.Catalog,
      FluxVale.Accounts,
      # #770: the pricing quote — the agent's truthful-cost seam.
      FluxVale.Pricing
    ],
    prefix: "/api/v1",
    open_api: "/open_api"
end

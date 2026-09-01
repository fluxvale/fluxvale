defmodule FluxValeWeb.AshJsonApiRouter do
  @moduledoc """
  JSON:API surface — first-class and day-one (ADR-0019). Mounted at
  `/api/json`; domains opt in via the `json_api` extension as they land
  (first resources: M2). `/api/json/open_api` serves the rendered OpenAPI
  spec, which feeds CLI/client generation later.
  """

  use AshJsonApi.Router,
    domains: [],
    open_api: "/open_api"
end

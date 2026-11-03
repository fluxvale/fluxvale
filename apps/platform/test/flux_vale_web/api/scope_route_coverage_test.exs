defmodule FluxValeWeb.Api.ScopeRouteCoverageTest do
  @moduledoc false

  # #360: every route the compiled AshJsonApiRouter serves must map in
  # the scope table — no unmapped /api/v1 route can ship (a token
  # caller on it would hit the deny-by-default 403). The REVERSE
  # (patterns without routes) is deliberately not asserted here: slice
  # 2 adds the routes this table already knows.

  use FluxVale.DataCase, async: true

  alias AshJsonApi.Domain.Info
  alias FluxVale.Api.Scopes

  test "every AshJsonApi route has a scope-table entry" do
    # The same enumeration `AshJsonApi.Router.formatted_routes/1` rides:
    # domain-level routes plus every resource's own json_api routes
    # (this app's shape today — User's /me lives on the resource).
    domain_routes =
      Enum.flat_map(FluxValeWeb.AshJsonApiRouter.domains(), &AshJsonApi.Domain.Info.routes/1)

    resource_routes =
      FluxValeWeb.AshJsonApiRouter.domains()
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.flat_map(&AshJsonApi.Resource.Info.routes/1)

    routes = Enum.concat(domain_routes, resource_routes)

    refute routes == []

    for route <- routes do
      # Route strings carry path params as ":name" segments — the
      # table's `:_` wildcards match those positionally, so the raw
      # split segments are the right probe.
      segments = String.split(route.route, "/", trim: true)

      assert {:ok, scope} = Scopes.required_scope(route.method, segments),
             "unmapped route: #{route.method} #{route.route}"

      assert scope == :any or is_binary(scope)
    end
  end
end

defmodule FluxValeWeb.Api.ScopeRouteCoverageTest do
  @moduledoc false

  # #360: the scope table and the shipped routes must agree BOTH
  # ways — no unmapped /api/v1 route can ship (a token caller on it
  # would hit the deny-by-default 403), and no table entry can go
  # dead (a pattern nothing serves is unreachable forever).

  use FluxVale.DataCase, async: true

  alias FluxVale.Api.Scopes

  test "every AshJsonApi route has a scope-table entry" do
    routes = shipped_routes()
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

  test "every scope-table pattern has a shipped route — no dead entries" do
    routes = shipped_routes()

    for {{method, pattern}, _scope} <- Scopes.route_table() do
      assert Enum.any?(routes, fn route ->
               # Route entities carry lowercase methods (atoms or
               # strings); the table rows are uppercase strings.
               String.upcase("#{route.method}") == method and
                 pattern_matches?(pattern, String.split(route.route, "/", trim: true))
             end),
             "dead pattern: #{method} /#{Enum.join(pattern, "/")}"
    end
  end

  # The same enumeration `AshJsonApi.Router.formatted_routes/1` rides:
  # domain-level routes plus every resource's own json_api routes
  # (this app's shape today — User's /me lives on the resource), plus
  # the router-level OpenAPI route — the `open_api: "/open_api"`
  # option in FluxValeWeb.AshJsonApiRouter, dispatched by ash_json_api
  # itself and invisible to the domain/resource enumeration
  # (open_api_route_test pins the served path).
  defp shipped_routes do
    domain_routes =
      Enum.flat_map(FluxValeWeb.AshJsonApiRouter.domains(), &AshJsonApi.Domain.Info.routes/1)

    resource_routes =
      FluxValeWeb.AshJsonApiRouter.domains()
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.flat_map(&AshJsonApi.Resource.Info.routes/1)

    # Enum.concat (not a cons) keeps the refute above honest — the
    # compiler can't prove the enumeration non-empty.
    Enum.concat(
      [%{method: "GET", route: "/open_api"}],
      Enum.concat(domain_routes, resource_routes)
    )
  end

  # The table's own shape, mirrored positionally: `:_` matches any
  # one route segment (":name" params included), a literal only
  # itself — a dead pattern must fail against every shipped route.
  defp pattern_matches?(pattern, segments) when length(pattern) == length(segments) do
    pattern
    |> Enum.zip(segments)
    |> Enum.all?(fn
      {:_, _segment} -> true
      {literal, segment} -> literal == segment
    end)
  end

  defp pattern_matches?(_pattern, _segments), do: false
end

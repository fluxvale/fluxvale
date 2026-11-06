defmodule FluxValeWeb.Api.OpenApiRouteTest do
  @moduledoc false

  # #360: the OpenAPI spec (the CLI-client generation source,
  # ADR-0019 §4) carries the new route families — authed, like every
  # /api/v1 route.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.ApiPat

  test "GET /api/v1/open_api includes the new paths", %{conn: conn} do
    {_user, pat} = ApiPat.member!()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> pat)
      |> get("/api/v1/open_api")

    # The spec endpoint answers its own media type — parse, don't
    # lean on the JSON:API content type.
    assert conn.status == 200
    assert body = Jason.decode!(conn.resp_body)

    paths =
      body["paths"]
      |> Map.keys()
      |> MapSet.new()

    # OpenAPI renders path params brace-style ({id}, not :id).
    for path <-
          MapSet.new([
            "/api/v1/instances",
            "/api/v1/instances/{id}/deploy",
            "/api/v1/instances/{id}/backup-runs",
            "/api/v1/instances/{id}/backup-runs/{backup_run_id}/restore",
            "/api/v1/backup-settings/{id}",
            "/api/v1/organizations/{organization_id}/access-gateway",
            "/api/v1/access-gateways/{id}/resume",
            "/api/v1/access-gateways/{gateway_id}/attachments",
            "/api/v1/access-domains",
            "/api/v1/organizations/{organization_id}/access-domains",
            "/api/v1/access-domains/{id}",
            "/api/v1/access-domains/{id}/resume",
            "/api/v1/organizations/{organization_id}/wallet",
            "/api/v1/organizations/{organization_id}/wallet/runway",
            "/api/v1/wallets/{wallet_id}/ledger-entries",
            "/api/v1/apps",
            "/api/v1/app-versions/{id}"
          ]) do
      assert path in paths, "expected #{path} in the spec"
    end
  end
end

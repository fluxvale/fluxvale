defmodule FluxValeWeb.Plugs.PinOpenApiRenderTest do
  @moduledoc false

  # The plug is the served twin's half of the artifact-equality
  # guarantee (#360 slice 4): after it runs, the module the dep's
  # `function_exported?/3` probe forgets to load must be loaded.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.ApiPat
  alias FluxValeWeb.Plugs.PinOpenApiRender

  test "init/1 passes options through" do
    assert PinOpenApiRender.init(mine: :opts) == [mine: :opts]
  end

  test "call/2 returns the conn untouched" do
    conn = build_conn()

    returned = PinOpenApiRender.call(conn, [])

    assert returned == conn
  end

  # No unit assertion CAN prove the pin here: `Code.ensure_loaded?/1`
  # loads as a side effect (true for any loadable module, plug or no
  # plug), and the once-per-VM flag may already be set by an earlier
  # async test. The pin's proof is end-to-end — the artifact-equality
  # suite in flux_vale.open_api_test.exs — plus the cold-boot probe
  # on the PR (bare cold render omits user-filter-email).
  test "the served open_api request rides it (scope-level, with the auth gate)" do
    {_user, pat} = ApiPat.member!()

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> pat)
      |> get("/api/v1/open_api")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["paths"] != %{}
  end
end

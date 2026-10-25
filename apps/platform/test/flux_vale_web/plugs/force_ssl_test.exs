defmodule FluxValeWeb.Plugs.ForceSSLTest do
  @moduledoc """
  The force_ssl exclusion contract (#256): kubelet readiness/liveness
  probes hit the pod directly over plain HTTP — no x-forwarded-proto,
  Host = pod IP — so /health and /health/ready must pass Plug.SSL
  untouched while every other path still 301s to https.

  The options exercised here are the real `config/prod.exs` ones,
  read with `Config.Reader.read!/1` — a pure read, so the running
  test app env is untouched — and the test endpoint is compiled
  without force_ssl (test env never sets it), so the SSL layer is
  driven explicitly and the conn then continues into the endpoint,
  mirroring how the prod pipeline orders the two.
  """

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.TestSupport.InstanceFixtures

  @prod_exs Path.expand("../../../config/prod.exs", __DIR__)
  @force_ssl @prod_exs
             |> Config.Reader.read!()
             |> get_in([:flux_vale, FluxValeWeb.Endpoint, :force_ssl])
  @ssl_opts Plug.SSL.init(@force_ssl)

  describe "health probe paths skip the SSL redirect over plain HTTP (#256)" do
    test "GET /health answers 200, not a redirect" do
      request = build_conn(:get, "/health")
      conn = Plug.SSL.call(request, @ssl_opts)

      refute conn.halted
      assert get_resp_header(conn, "location") == []

      endpoint_args = FluxValeWeb.Endpoint.init([])
      response = FluxValeWeb.Endpoint.call(conn, endpoint_args)
      assert response.status == 200
    end

    test "GET /health/ready answers 200, not a redirect" do
      # Readiness gates on the reference-data invariants (#175) — the
      # fixtures satisfy them so the endpoint's answer is the healthy 200
      # the kubelet expects, and the assertion stays about the redirect.
      InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      request = build_conn(:get, "/health/ready")
      conn = Plug.SSL.call(request, @ssl_opts)

      refute conn.halted
      assert get_resp_header(conn, "location") == []

      endpoint_args = FluxValeWeb.Endpoint.init([])
      response = FluxValeWeb.Endpoint.call(conn, endpoint_args)
      assert response.status == 200
    end

    test "GET /metrics stays off the redirect too (in-cluster scrapers, #115)" do
      request = build_conn(:get, "/metrics")
      conn = Plug.SSL.call(request, @ssl_opts)

      refute conn.halted
      assert get_resp_header(conn, "location") == []
    end
  end

  test "an ordinary path over plain HTTP still 301s to https" do
    request = build_conn(:get, "/apps")
    response = Plug.SSL.call(request, @ssl_opts)

    assert response.halted
    assert response.status == 301
    assert ["https://www.example.com/apps"] = get_resp_header(response, "location")
  end
end

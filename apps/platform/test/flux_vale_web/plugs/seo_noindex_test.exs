defmodule FluxValeWeb.Plugs.SeoNoindexTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias FluxValeWeb.Plugs.SeoNoindex

  describe "call/2" do
    test "the canonical prod host is a no-op" do
      conn = SeoNoindex.call(%{build_conn() | host: "fluxvale.com"}, [])

      assert get_resp_header(conn, "x-robots-tag") == []
      refute conn.assigns[:robots_noindex]
    end

    test "host case is normalized (RFC 9110 — Host is case-insensitive)" do
      conn = SeoNoindex.call(%{build_conn() | host: "FLUXVALE.COM"}, [])

      assert get_resp_header(conn, "x-robots-tag") == []
      refute conn.assigns[:robots_noindex]
    end

    test "staging gets the X-Robots-Tag header and the layout assign" do
      conn = SeoNoindex.call(%{build_conn() | host: "staging.fluxvale.com"}, [])

      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert conn.assigns.robots_noindex
    end

    test "PR review and local dev hosts are covered too" do
      for host <- ["pr-42.review.fluxvale.com", "app.fluxvale.lvh.me", "localhost"] do
        conn = SeoNoindex.call(%{build_conn() | host: host}, [])

        assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"],
               "expected noindex for #{host}"

        assert conn.assigns.robots_noindex
      end
    end
  end
end

defmodule FluxValeWeb.Plugs.RawBodyTest do
  @moduledoc """
  RawBody contract (#136): the exact request bytes survive Plug.Parsers
  for webhook signature verification.
  """

  use ExUnit.Case, async: true

  alias FluxValeWeb.Plugs.RawBody

  test "captures the full body while parsing proceeds" do
    conn = Phoenix.ConnTest.build_conn(:post, "/", ~s({"id":"pr_1"}))

    assert {:ok, ~s({"id":"pr_1"}), captured} = RawBody.read_body(conn, [])
    assert captured.assigns[:raw_body] == ~s({"id":"pr_1"})
  end

  test "streams partial reads through (large bodies arrive in chunks)" do
    conn = Phoenix.ConnTest.build_conn(:post, "/", "chunked")

    assert {:more, "c", _conn} = RawBody.read_body(conn, length: 1)
  end
end

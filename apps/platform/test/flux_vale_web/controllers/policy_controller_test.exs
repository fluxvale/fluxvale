defmodule FluxValeWeb.PolicyControllerTest do
  @moduledoc false

  # The published policies (#140): anonymous-OK — a policy the buyer
  # can't read before paying isn't a policy.

  use FluxValeWeb.ConnCase, async: true

  describe "GET /policies/refund" do
    test "states the decided stance for anonymous visitors", %{conn: conn} do
      conn = get(conn, ~p"/policies/refund")
      html = html_response(conn, 200)

      assert html =~ "Refund policy"
      assert html =~ "Credits are non-refundable"
      assert html =~ "balance never expires"

      # The goodwill exception is offered WITHOUT promising a refund
      # channel: credit, never money back, human decides.
      assert html =~ "at our discretion"
      assert html =~ "money back to a payment method"

      # Chargebacks: the structural posture, stated plainly.
      assert html =~ "no recurring billing"
    end

    test "carries the SEO assigns the root layout renders", %{conn: conn} do
      conn = get(conn, ~p"/policies/refund")

      assert conn.assigns.page_title == "Refund policy · FluxVale"

      assert conn.assigns.page_description ==
               "FluxVale credits are non-refundable and never expire"

      assert conn.assigns.canonical_path == "/policies/refund"
    end
  end
end

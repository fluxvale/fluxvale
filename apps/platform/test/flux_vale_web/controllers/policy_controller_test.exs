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

  # #365: the legal-foundation pages — same anonymous-OK contract as the
  # refund policy. The load-bearing wording is asserted verbatim: the
  # operating entity, the credits stance (mirroring the published refund
  # policy), the accurate networking statement, the decided parameters
  # (Philippines law and venue, the 12-month cap, the contact address),
  # and the non-committal post-termination data line.
  describe "GET /policies/terms" do
    test "states the governing terms for anonymous visitors", %{conn: conn} do
      conn = get(conn, ~p"/policies/terms")
      html = html_response(conn, 200)

      assert html =~ "Terms of Service"
      assert html =~ "Last updated:"
      assert html =~ "FLUXVALE INFORMATION"
      assert html =~ "SOLUTIONS OPC"

      # The credits clause mirrors the refund policy.
      assert html =~ "prepaid wallet"
      assert html =~ "never expire"
      assert html =~ "non-refundable"
      assert html =~ "don't store card details on the platform"
      assert html =~ "suspends your instances instead of accruing debt"
      assert html =~ ~s(href="/policies/refund")

      # Networking stated accurately — and the default is NOT phrased as
      # "private-by-default", which is not the product's default.
      assert html =~ "fluxvale.app subdomain"
      assert html =~ "no public address at all"
      assert html =~ "only through your own private network"
      refute html =~ "private-by-default"

      # The decided parameters.
      assert html =~ "laws of the Philippines"
      assert html =~ "courts of the Philippines"
      assert html =~ "12 months before that claim"
      assert html =~ "admin@fluxvale.com"

      # Post-termination data stays non-committal — no committed window.
      assert html =~ "We may delete your data after termination"
      refute html =~ ~r/deleted? (within|after) \d+/

      assert html =~ ~s(data-testid="terms-of-service")
    end

    test "carries the SEO assigns the root layout renders", %{conn: conn} do
      conn = get(conn, ~p"/policies/terms")

      assert conn.assigns.page_title == "Terms of Service · FluxVale"
      assert conn.assigns.page_description == "The agreement between you and FluxVale"
      assert conn.assigns.canonical_path == "/policies/terms"
    end
  end

  describe "GET /policies/acceptable-use" do
    test "bans the decided classes for anonymous visitors", %{conn: conn} do
      conn = get(conn, ~p"/policies/acceptable-use")
      html = html_response(conn, 200)

      assert html =~ "Acceptable Use Policy"

      # The banned classes, verbatim from the decided outline.
      assert html =~ "Cryptocurrency mining"
      assert html =~ "mining pools and token"
      assert html =~ "Torrents, P2P file sharing, and warez"
      assert html =~ "Bulk email, spamming, and unsolicited messaging"
      assert html =~ "Scraping and bulk automated harvesting"
      assert html =~ "botnets"
      assert html =~ "command-and-control infrastructure"
      assert html =~ "DDoS and booter services"
      assert html =~ "Circumventing platform limits or security"

      # Enforcement: investigate + suspend/terminate, credits stay
      # non-refundable on enforcement termination.
      assert html =~ "investigate suspected violations"
      assert html =~ "suspend or terminate"
      assert html =~ "credits"
      assert html =~ "non-refundable"
      assert html =~ "admin@fluxvale.com"

      assert html =~ ~s(data-testid="acceptable-use-policy")
    end

    test "carries the SEO assigns the root layout renders", %{conn: conn} do
      conn = get(conn, ~p"/policies/acceptable-use")

      assert conn.assigns.page_title == "Acceptable Use Policy · FluxVale"

      assert conn.assigns.page_description ==
               "What you may and may not run on FluxVale"

      assert conn.assigns.canonical_path == "/policies/acceptable-use"
    end
  end
end

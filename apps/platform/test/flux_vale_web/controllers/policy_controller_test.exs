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
      assert html =~ "Wallet balance is non-refundable"
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
               "FluxVale wallet balance is non-refundable and never expires"

      assert conn.assigns.canonical_path == "/policies/refund"
    end
  end

  # #365: the legal-foundation pages — same anonymous-OK contract as the
  # refund policy. The load-bearing wording is asserted verbatim: the
  # operating entity, the wallet stance (mirroring the published refund
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

      # The wallet clause mirrors the refund policy.
      assert html =~ "prepaid wallet"
      assert html =~ "never expires"
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

      # #642: the Google-account clause — the owner's responsibility
      # line and the email-code door staying open (plan §8). The
      # sentences wrap in source; assert against a whitespace-
      # flattened copy (the privacy test's idiom).
      flat = String.replace(html, ~r/\s+/, " ")
      assert flat =~ "You may sign in with a Google account"
      assert flat =~ "Keeping that Google account secure is your responsibility"
      assert flat =~ "email-code sign-in remains available"
      assert flat =~ "to the email addresses you have verified with us"

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

      # Enforcement: investigate + suspend/terminate, wallet balance
      # stays non-refundable on enforcement termination. The clause
      # wraps in source; assert the flattened copy (the privacy test's
      # idiom — HTML collapses the whitespace at render anyway).
      flat = String.replace(html, ~r/\s+/, " ")
      assert html =~ "investigate suspected violations"
      assert html =~ "suspend or terminate"
      assert flat =~ "wallet balance stays non-refundable"
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

  describe "GET /policies/privacy" do
    # fv332 D5: the privacy text of record. The load-bearing wording is
    # asserted verbatim: the entity, the measurement claim (verified
    # against the code — Umami is the self-hosted, cookieless tag of
    # FluxValeWeb.SiteAnalytics, public pages only, and #706/ADR-0049
    # names PostHog for the signed-in app ahead of its env flip), the
    # never-collect claims (card data never touches the platform), the
    # BYO-backup posture, the financial-records retention stance
    # (docs/data-deletion.md), and the PH-law framing consistent with
    # the terms.
    test "states the privacy stance for anonymous visitors", %{conn: conn} do
      conn = get(conn, ~p"/policies/privacy")
      html = html_response(conn, 200)

      # Source wrapping splits phrases across lines; assert against a
      # whitespace-flattened copy (HTML collapses it at render anyway).
      flat = String.replace(html, ~r/\s+/, " ")

      assert html =~ "Privacy policy"
      assert html =~ "Last updated:"
      assert flat =~ "FLUXVALE INFORMATION SOLUTIONS OPC"

      # The measurement claim and the never-collect claims, stated as
      # facts about the platform (#576: SiteAnalytics carries the
      # Umami tag; #706: PostHog is named for the signed-in app ahead
      # of its env flip — the policy leads, ADR-0049).
      assert flat =~ "never see your card details"

      # Umami: still self-run, still public-pages only.
      assert flat =~ "public pages with Umami"
      assert flat =~ "cookieless analytics service we run ourselves"
      assert flat =~ "It never loads on the signed-in app"

      # PostHog: the named operator (PostHog, Inc.), the in-app scope,
      # what it records (pages, buttons, errors), the account
      # identifier, cookieless, instance-blind (#712 fix round).
      assert flat =~ "Inside the signed-in app we use PostHog"
      assert flat =~ "analytics service run by PostHog, Inc."
      assert flat =~ "PostHog records which pages you open and which buttons you press"
      assert flat =~ "collects errors you hit"
      assert flat =~ "Events are tied to your account with an identifier our server supplies"
      assert flat =~ "sets no cookies and stores nothing on your device"
      assert flat =~ "cannot read the data inside your instances"
      assert flat =~ "No advertising trackers ride our pages"
      # The old promise dies with the third-party tag: it must not
      # survive the PostHog rider.
      refute flat =~ "we run no tracker we do not own"

      assert flat =~ "do not read, scan, or mine"

      # App data: isolated per instance, backups go to storage the
      # customer brings, control backups exclude app data.
      assert flat =~ "its own isolated space"
      assert flat =~ "storage you bring"
      assert flat =~ "do not contain your app data"

      # Billing collection includes the checkout's buyer and tax
      # evidence (the topup resource's fields, verified) and the
      # wallet-entry record (#641's wording).
      assert flat =~ "the record of every entry that adds to or draws down that balance"
      assert flat =~ "buyer name and email"
      assert flat =~ "the country your connection came from"

      # #642: Google as an identity provider — the card states the
      # arm's exact data posture (plan §8, D-scopes: openid email,
      # nothing kept beyond the address, email codes still the door).
      assert flat =~ "You can sign in with a Google account"
      assert flat =~ "confirms that Google has verified it"
      assert flat =~ "We ask for nothing else"
      assert flat =~ "we do not send Google any data about you"
      assert flat =~ "Nothing from your Google account is stored here"
      assert flat =~ "No profile, no name, no picture"
      assert flat =~ "Google is an identity provider for sign-in"
      assert flat =~ "Google's privacy policy"
      assert flat =~ "email-code sign-in keeps working"

      # Email is transactional only; codes are hashed, single use, and
      # short-lived.
      assert flat =~ "no marketing mailing list"
      assert flat =~ "single use"
      assert flat =~ "expire ten minutes"
      assert flat =~ "Postmark"

      # Logs: honest about IP addresses, bounded retention, named
      # monitoring services. PostHog rides beside Grafana Cloud
      # (#706); traces are disclosed here and their export activates
      # with this slice (Phase 2).
      assert flat =~ "IP addresses"
      assert flat =~ "limited window"
      assert flat =~ "Grafana Cloud"
      assert flat =~ "also go to PostHog, a second analytics service"
      # PostHog-only fragment: Grafana's sentence does not carry it.
      assert flat =~ "carry no cookies and no advertising trackers"
      assert flat =~ "advertise to you or to profile you"
      assert flat =~ "Technical traces of requests in the signed-in app also go to PostHog"

      # Retention: the one category that outlives an account, said
      # plainly (the data-deletion stance).
      assert flat =~ "Bookkeeping law in the Philippines"
      assert flat =~ "amounts and references, never"

      # Deletion: instance destroy is real deletion; account deletion
      # goes through admin@ with the retention caveat repeated.
      assert flat =~ "deletes it and its data for good"
      assert flat =~ "write to admin@fluxvale.com"

      # Security + choices + law: hashes for codes and PATs (sessions
      # are signed, revocable — the claim stops where the code stops),
      # settings-level self-service only (no surface-less promises).
      assert flat =~ "cryptographic hashes"
      assert flat =~ "revoke instantly"
      assert flat =~ "from the app's settings"
      refute flat =~ "sign out of every session"
      refute flat =~ "revoke personal access tokens yourself"
      assert flat =~ "support@fluxvale.com"
      assert flat =~ "laws of the Philippines"
      assert flat =~ "Data Privacy Act"

      # The page's one outbound cross-link rides the sibling shape.
      assert html =~ ~s(href="/policies/terms")
      assert html =~ ~s(data-testid="privacy-policy")
    end

    test "carries the SEO assigns the root layout renders", %{conn: conn} do
      conn = get(conn, ~p"/policies/privacy")

      assert conn.assigns.page_title == "Privacy policy · FluxVale"

      assert conn.assigns.page_description ==
               "What FluxVale collects, what it never collects, and how your data is handled"

      assert conn.assigns.canonical_path == "/policies/privacy"
    end

    test "links from the chrome footer beside the other legal pages", %{conn: conn} do
      conn = get(conn, ~p"/policies/privacy")
      html = html_response(conn, 200)

      # Layouts.public renders the shared footer (#365 posture): privacy
      # rides every chrome'd surface.
      assert html =~ ~s(data-testid="footer-privacy")
      assert html =~ ~s(href="/policies/privacy")
      assert html =~ ~s(data-testid="footer-terms")
    end
  end
end

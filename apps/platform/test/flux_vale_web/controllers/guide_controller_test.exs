defmodule FluxValeWeb.GuideControllerTest do
  @moduledoc false

  # The sign-in-with-Pocket ID guide (#511): anonymous-OK like the
  # policies. The load-bearing wording is asserted — the honest-copy
  # weights first (always-on identity, destroy-means-identity-loss),
  # then the per-app wiring and the pinned callback paths (mirroring
  # the catalog seed's oidc_callback_path values, so the two ends
  # cannot drift apart silently).

  use FluxValeWeb.ConnCase, async: true

  describe "GET /guides/sign-in-with-pocket-id" do
    test "walks the wiring for anonymous visitors", %{conn: conn} do
      conn = get(conn, ~p"/guides/sign-in-with-pocket-id")
      html = html_response(conn, 200)

      assert html =~ "Sign in with Pocket ID"
      assert html =~ "What this gives you"

      # Deploy order: the env-configured apps need the client first.
      assert html =~ "Deploy Pocket ID first"
      assert html =~ "Vaultwarden,"
      assert html =~ "ActualBudget, and Vikunja read their provider settings"
      assert html =~ "redeploying it with the values"

      # The issuer must be reachable from app containers — keep it
      # public.
      assert html =~ "from the app's container"
    end

    test "states the always-on weight where sizing is discussed", %{conn: conn} do
      conn = get(conn, ~p"/guides/sign-in-with-pocket-id")
      html = html_response(conn, 200)
      flat = String.replace(html, ~r/\s+/, " ")

      assert html =~ "Keep Pocket ID awake"
      assert flat =~ "Run the identity instance always-on"
      # The sleeping failure mode, named plainly, with its blast radius.
      assert flat =~ "error with a retry hint"
      assert flat =~ "every app that points at it fails with them"
    end

    test "states the destroy weight and the recovery materials", %{conn: conn} do
      conn = get(conn, ~p"/guides/sign-in-with-pocket-id")
      html = html_response(conn, 200)
      flat = String.replace(html, ~r/\s+/, " ")

      assert html =~ ~s(data-testid="destroy-loses-identities")
      assert flat =~ "The identities it holds are lost with it"
      # The recovery materials, named: backup password + encryption key.
      assert flat =~ "the backup password and"
      assert flat =~ "the encryption key you chose at deploy"
    end

    test "carries the six apps and their pinned callback paths", %{conn: conn} do
      conn = get(conn, ~p"/guides/sign-in-with-pocket-id")
      html = html_response(conn, 200)

      assert html =~ "Forgejo"
      assert html =~ "Kavita"
      assert html =~ "Vaultwarden"
      assert html =~ "ActualBudget"
      assert html =~ "Memos"
      assert html =~ "Vikunja"

      # The same values the catalog seed pins (catalog_seed_test's
      # #511 test) — a doc that drifts from the data is a lie.
      assert html =~ "/user/oauth2/PocketID/callback"
      assert html =~ "/signin-oidc"
      assert html =~ "/identity/connect/oidc-signin"
      assert html =~ "/openid/callback"
      assert html =~ "/auth/callback"
      assert html =~ "/auth/openid/pocketid"
    end

    test "carries the honest per-app notes", %{conn: conn} do
      conn = get(conn, ~p"/guides/sign-in-with-pocket-id")
      html = html_response(conn, 200)
      flat = String.replace(html, ~r/\s+/, " ")

      # Forgejo: the auth source name is part of the callback path.
      assert flat =~ "Name it PocketID, because the name is part of the callback path"
      # Kavita: the optional logout callback, the catalog comment's claim.
      assert flat =~ "/signout-callback-oidc as the client's logout callback"
      # Vaultwarden: master password + the second-passkey circularity,
      # and PKCE stated without contradiction (the client side is the
      # opt-in, Vaultwarden's own default matches it).
      assert flat =~ "The master password still unlocks the vault"
      assert flat =~ "second passkey for Pocket ID somewhere outside Vaultwarden"
      assert flat =~ "Vaultwarden uses PKCE by default"
      refute flat =~ "PKCE is on by default on both ends"
      # ActualBudget: the discovery URL input takes the Pocket ID URL,
      # and the first OpenID sign-in becomes the server owner.
      assert flat =~ "The discovery URL is your Pocket ID instance's public URL"
      assert flat =~ "becomes the server owner"
      # Memos: keep one admin password as the recovery path.
      assert flat =~ "Keep one admin password login as your recovery path"
      # Vikunja: PKCE off (its client sends no challenge), the issuer
      # with no trailing slash, and the display name is label-only.
      assert flat =~ "For the Vikunja client, leave PKCE off"
      assert flat =~ "public URL with no trailing slash. It must match exactly"
      assert flat =~ "whatever the display name says"
      # The suite-wide posture: one local way in, platform sign-in
      # independent.
      assert flat =~ "Keep one local way in per app"
      assert flat =~ "never depends on Pocket ID"
    end

    test "links from the chrome footer beside the legal pages", %{conn: conn} do
      conn = get(conn, ~p"/guides/sign-in-with-pocket-id")
      html = html_response(conn, 200)

      assert html =~ ~s(data-testid="footer-guides")
      assert html =~ ~s(href="/guides/sign-in-with-pocket-id")
    end

    test "carries the SEO assigns the root layout renders", %{conn: conn} do
      conn = get(conn, ~p"/guides/sign-in-with-pocket-id")

      assert conn.assigns.page_title == "Sign in with Pocket ID · FluxVale"

      assert conn.assigns.page_description ==
               "One passkey identity for your app suite, wired app by app"

      assert conn.assigns.canonical_path == "/guides/sign-in-with-pocket-id"
    end

    test "the platform-flow section sits beside the manual path", %{conn: conn} do
      conn = get(conn, ~p"/guides/sign-in-with-pocket-id")
      html = html_response(conn, 200)
      flat = String.replace(html, ~r/\s+/, " ")

      assert html =~ "The automatic way"
      assert html =~ "Sign in with your Pocket ID"
      assert html =~ "Settings → API keys"
      # The scope names both covered apps (Vikunja joined the recipe).
      assert flat =~ "The automatic path currently covers Vaultwarden and Vikunja"
      # The real card label on the Pocket ID instance page.
      assert flat =~ "Sign-in with Pocket ID"
      # The manual path stays.
      assert html =~ "Wire Vaultwarden"
    end
  end
end

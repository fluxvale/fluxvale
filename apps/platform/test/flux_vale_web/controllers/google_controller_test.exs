defmodule FluxValeWeb.GoogleControllerTest do
  @moduledoc """
  Plan §7's controller-level matrix for the Google arm (#642): every
  hop through the real router against the mock OIDC provider over real
  HTTP — assent's discovery/state/PKCE/signature chain included, so
  nothing in `lib/` knows the provider is fake.
  """

  use FluxValeWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Identity.User
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.TestSupport.OIDC.Provider

  @client_id "mock-client-id"
  @client_secret "mock-client-secret"

  @unavailable "Google sign-in isn't available here. Use an email code."
  @oidc_failed "Google sign-in didn't complete. Use an email code."
  @throttled "Please wait a minute before trying again."

  setup do
    provider = start_supervised!({Provider, client_id: @client_id, client_secret: @client_secret})

    original = Application.get_env(:flux_vale, :google_oidc)

    Application.put_env(:flux_vale, :google_oidc,
      client_id: @client_id,
      client_secret: @client_secret,
      issuer: Provider.base_url(provider)
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :google_oidc)
        value -> Application.put_env(:flux_vale, :google_oidc, value)
      end
    end)

    # Runtime DB state the admin flips (D-flag): no seed exists — the
    # row is the on-switch. One unique remote IP per test keeps the
    # day-long suite throttle window per-test isolated.
    FeatureFlag.create!("google_sign_in", %{enabled: true}, authorize?: false)

    ip = {10, unique_octet(), unique_octet(), unique_octet()}
    %{provider: provider, ip: ip}
  end

  defp as_ip(conn, ip), do: %{conn | remote_ip: ip}

  # The browser's authorize round trip through the mock: our hop's
  # redirect, the provider's /authorize (the user-authenticates-at-
  # Google stand-in), and the code+state echoed back — the exact dance
  # google_oidc_test drives at the seam.
  defp authorize_hop(conn, params \\ %{}) do
    conn = get(conn, ~p"/auth/google?#{params}")
    url = redirected_to(conn, 302)
    assert url =~ "/authorize"

    response = Req.get!(url: url, redirect: false)
    assert response.status == 302

    [callback] = Req.Response.get_header(response, "location")

    query =
      callback
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()

    %{conn: conn, code: query["code"], state: query["state"]}
  end

  defp callback_hop(grant, ip) do
    grant.conn
    |> recycle()
    |> as_ip(ip)
    |> get(~p"/auth/google/callback?#{%{code: grant.code, state: grant.state}}")
  end

  defp error_flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)

  defp signed_in_user(conn) do
    session = Plug.Conn.get_session(conn)
    FluxValeWeb.UserAuth.resolve_user(session)
  end

  describe "the round trip" do
    test "signs in an existing verified-email user, honoring return_to", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      email = "google-web-#{System.unique_integer()}@fluxvale.com"
      user = User.create!(email, %{}, authorize?: false)

      Provider.set_claims(provider, email: email, email_verified: true, sub: "g-sub-1")

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop(%{return_to: "/feedback"})

      result = callback_hop(grant, ip)

      assert redirected_to(result) == "/feedback"
      assert Phoenix.Flash.get(result.assigns.flash, :info) == "Signed in with Google."
      assert %{id: id} = signed_in_user(result)
      assert id == user.id
      # Exactly one token redemption for the whole round trip
      assert Provider.redemptions(provider) == 1
    end

    test "an external return_to is dropped — the callback lands on /", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      email = "google-open-redirect-#{System.unique_integer()}@fluxvale.com"
      User.create!(email, %{}, authorize?: false)
      Provider.set_claims(provider, email: email, email_verified: true)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop(%{return_to: "//evil.com"})

      result = callback_hop(grant, ip)

      assert redirected_to(result) == ~p"/"
    end

    test "JIT-creates the team-domain account (the same bypass as codes)", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      email = "google-jit-#{System.unique_integer()}@fluxvale.com"
      Provider.set_claims(provider, email: email, email_verified: true)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop()

      result = callback_hop(grant, ip)

      assert redirected_to(result) == ~p"/"
      assert Phoenix.Flash.get(result.assigns.flash, :info) == "Signed in with Google."
      assert {:ok, %{id: id}} = User.get_by_email(email, authorize?: false)
      assert %{id: ^id} = signed_in_user(result)
    end
  end

  describe "admission refusals (the ladder's honest copy)" do
    test "an unknown non-team address meets the invitation wall", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      email = "google-wall-#{System.unique_integer()}@partner.example"
      Provider.set_claims(provider, email: email, email_verified: true)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop()

      result = callback_hop(grant, ip)

      assert redirected_to(result) == ~p"/sign-in"
      assert error_flash(result) =~ "invitation-only early access"
      assert error_flash(result) =~ "support@fluxvale.com"
      assert signed_in_user(result) == nil
    end

    test "an outstanding invite is pointed at its accept link", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      email = "google-invited-#{System.unique_integer()}@partner.example"
      {_invited, _raw} = invite_user!(email)
      Provider.set_claims(provider, email: email, email_verified: true)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop()

      result = callback_hop(grant, ip)

      assert redirected_to(result) == ~p"/sign-in"
      assert error_flash(result) =~ "invitation waiting"
      # The invited account still exists, unmolested — the emailed
      # link is its door, and no session was minted
      assert {:ok, _invited} = User.get_by_address(email, authorize?: false)
      assert signed_in_user(result) == nil
    end

    test "an unverified Google claim refuses before any lookup", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      email = "google-unverified-#{System.unique_integer()}@fluxvale.com"
      Provider.set_claims(provider, email: email, email_verified: false)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop()

      result = callback_hop(grant, ip)

      assert redirected_to(result) == ~p"/sign-in"
      assert error_flash(result) =~ "isn't verified by Google"
      assert error_flash(result) =~ "email code"
      assert signed_in_user(result) == nil
      assert {:error, _not_found} = User.get_by_email(email, authorize?: false)
    end
  end

  describe "transport failures (the controller's error set)" do
    test "a state mismatch answers the fallback copy and writes no session — zero outbound redemptions",
         %{
           conn: conn,
           ip: ip,
           provider: provider
         } do
      Provider.set_claims(provider, email: "whoever@example.com", email_verified: true)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop(%{return_to: "/feedback"})

      # The session rides the recycled authorize conn; the forged
      # state dies inside assent's constant-time compare — BEFORE any
      # outbound token request (the provider's redemption count is the
      # outbound-budget probe)
      result =
        grant.conn
        |> recycle()
        |> as_ip(ip)
        |> get(~p"/auth/google/callback?#{%{code: grant.code, state: "forged-state"}}")

      assert redirected_to(result) == "/sign-in?return_to=%2Ffeedback"
      assert error_flash(result) == @oidc_failed
      assert signed_in_user(result) == nil
      assert Provider.redemptions(provider) == 0
    end

    # MUST-FIX: repeated or indexed form keys arrive as lists/maps —
    # assent's constant-time compare and URI encoding are binary-only,
    # so the malformed shape must die at the honest copy, never raise.
    test "a list-shaped state reaches no assent compare — the honest copy, not a 500", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      Provider.set_claims(provider, email: "whoever@example.com", email_verified: true)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop()

      result =
        grant.conn
        |> recycle()
        |> as_ip(ip)
        |> get("/auth/google/callback?state[]=x&code=#{grant.code}")

      assert result.status == 302
      assert redirected_to(result) == ~p"/sign-in"
      assert error_flash(result) == @oidc_failed
      assert Provider.redemptions(provider) == 0
    end

    test "a map-shaped code is refused the same way", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      Provider.set_claims(provider, email: "whoever@example.com", email_verified: true)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop()

      result =
        grant.conn
        |> recycle()
        |> as_ip(ip)
        |> get("/auth/google/callback?code[foo]=bar&state=#{grant.state}")

      assert result.status == 302
      assert redirected_to(result) == ~p"/sign-in"
      assert error_flash(result) == @oidc_failed
      assert Provider.redemptions(provider) == 0
    end

    test "a replayed callback dies on the consumed round trip — no second redemption", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      email = "google-replay-#{System.unique_integer()}@fluxvale.com"
      User.create!(email, %{}, authorize?: false)
      Provider.set_claims(provider, email: email, email_verified: true)

      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop()

      first = callback_hop(grant, ip)
      assert Phoenix.Flash.get(first.assigns.flash, :info) == "Signed in with Google."
      assert Provider.redemptions(provider) == 1

      # The session_params were consumed with the first hop: the
      # replay has nothing to validate against (and the code is long
      # burned at the provider anyway) — no outbound call either way.
      replay =
        first
        |> recycle()
        |> as_ip(ip)
        |> get(~p"/auth/google/callback?#{%{code: grant.code, state: grant.state}}")

      assert redirected_to(replay) == ~p"/sign-in"
      assert error_flash(replay) == @oidc_failed
      assert Provider.redemptions(provider) == 1
    end

    test "a cold callback (nothing parked) answers the fallback copy — no destination to keep", %{
      conn: conn,
      ip: ip
    } do
      conn
      |> as_ip(ip)
      |> get(~p"/auth/google/callback?#{%{code: "cold", state: "cold"}}")
      |> then(fn result ->
        assert redirected_to(result) == ~p"/sign-in"
        assert error_flash(result) == @oidc_failed
        assert signed_in_user(result) == nil
      end)
    end

    test "an unreachable issuer fails the authorize hop with the fallback copy + a server-side log",
         %{conn: conn, ip: ip} do
      Application.put_env(:flux_vale, :google_oidc,
        client_id: @client_id,
        client_secret: @client_secret,
        # Port 1 on loopback: nothing listens there
        issuer: "http://127.0.0.1:1"
      )

      {result, output} =
        with_log(fn ->
          conn
          |> as_ip(ip)
          |> get(~p"/auth/google?#{%{return_to: "/feedback"}}")
        end)

      # §5: even the transport failure keeps the destination
      assert redirected_to(result) == "/sign-in?return_to=%2Ffeedback"
      assert error_flash(result) == @oidc_failed
      # The reason is server-side only, bounded by the inspect limits
      assert output =~ "Google OIDC authorize hop failed"
    end
  end

  describe "the door-shut predicate (D-flag)" do
    test "flag off: both hops refuse with the unavailable copy, destination kept", %{
      conn: conn,
      ip: ip
    } do
      row = FeatureFlag.by_key!("google_sign_in", authorize?: false, not_found_error?: false)
      Ash.update!(row, %{enabled: false}, authorize?: false)

      conn
      |> as_ip(ip)
      |> get(~p"/auth/google?#{%{return_to: "/feedback"}}")
      |> then(fn result ->
        assert redirected_to(result) == "/sign-in?return_to=%2Ffeedback"
        assert error_flash(result) == @unavailable
        assert signed_in_user(result) == nil
      end)

      # The callback refuses identically — nothing parked, so no
      # destination to keep (bare /sign-in)
      conn
      |> as_ip(ip)
      |> get(~p"/auth/google/callback?#{%{code: "any", state: "any"}}")
      |> then(fn result ->
        assert redirected_to(result) == ~p"/sign-in"
        assert error_flash(result) == @unavailable
      end)
    end

    test "flag flipped mid-round-trip: the callback's refusal keeps the parked destination", %{
      conn: conn,
      ip: ip
    } do
      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop(%{return_to: "/feedback"})

      row = FeatureFlag.by_key!("google_sign_in", authorize?: false, not_found_error?: false)
      Ash.update!(row, %{enabled: false}, authorize?: false)

      grant.conn
      |> recycle()
      |> as_ip(ip)
      |> get(~p"/auth/google/callback?#{%{code: grant.code, state: grant.state}}")
      |> then(fn result ->
        assert redirected_to(result) == "/sign-in?return_to=%2Ffeedback"
        assert error_flash(result) == @unavailable
        assert signed_in_user(result) == nil
      end)
    end

    test "credentials absent: both hops make the same refusal", %{conn: conn, ip: ip} do
      Application.put_env(:flux_vale, :google_oidc, client_id: nil, client_secret: nil)

      conn
      |> as_ip(ip)
      |> get(~p"/auth/google")
      |> then(fn result ->
        assert redirected_to(result) == ~p"/sign-in"
        assert error_flash(result) == @unavailable
      end)

      conn
      |> as_ip(ip)
      |> get(~p"/auth/google/callback?#{%{code: "any", state: "any"}}")
      |> then(fn result ->
        assert redirected_to(result) == ~p"/sign-in"
        assert error_flash(result) == @unavailable
      end)
    end
  end

  describe "the per-IP throttle (D-abuse)" do
    test "both hops count; overflow answers the browser-shaped copy, never a 429", %{
      conn: conn,
      ip: ip,
      provider: provider
    } do
      Provider.set_claims(provider,
        email: "google-throttle-#{System.unique_integer()}@fluxvale.com",
        email_verified: true
      )

      original = Application.get_env(:flux_vale, FluxValeWeb.Plugs.GoogleRateLimit)

      Application.put_env(:flux_vale, FluxValeWeb.Plugs.GoogleRateLimit,
        window_seconds: 86_400,
        max_requests: 2
      )

      on_exit(fn ->
        Application.put_env(:flux_vale, FluxValeWeb.Plugs.GoogleRateLimit, original)
      end)

      # Hop 1 and 2 pass —
      grant =
        conn
        |> as_ip(ip)
        |> authorize_hop()

      result = callback_hop(grant, ip)
      assert Phoenix.Flash.get(result.assigns.flash, :info) == "Signed in with Google."

      # — the third request on the same IP meets the throttle copy,
      # destination still attached (§5: the email fallback forgets
      # nothing)
      conn
      |> as_ip(ip)
      |> get(~p"/auth/google?#{%{return_to: "/feedback"}}")
      |> then(fn refused ->
        assert refused.status == 302
        assert redirected_to(refused) == "/sign-in?return_to=%2Ffeedback"
        assert error_flash(refused) == @throttled
      end)

      # …and the callback hop counts too: a fourth request (a replayed
      # code against the already-consumed round trip) gets the same
      # browser-shaped refusal, never a 429
      conn
      |> as_ip(ip)
      |> get(~p"/auth/google/callback?#{%{code: grant.code, state: grant.state}}")
      |> then(fn refused ->
        assert refused.status == 302
        assert error_flash(refused) == @throttled
      end)
    end
  end

  defp unique_octet, do: rem(System.unique_integer([:positive]), 250)
end

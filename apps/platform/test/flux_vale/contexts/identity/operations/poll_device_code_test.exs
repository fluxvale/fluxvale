defmodule FluxVale.Identity.Operations.PollDeviceCodeTest do
  @moduledoc false

  # #362 T3: the poll machine (RFC 8628 §3.5's answer order) —
  # pending → approved → consumed with slow_down in between, and the
  # one-time grant that carries provenance into the minted PAT.

  # Not async: one test opens the global Logger level to capture the
  # info lines (the token-never-logged proof) — a node-global; the
  # runtime_config_test posture for VM-global state.
  use FluxVale.DataCase, async: false

  import ExUnit.CaptureLog

  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.Operations.PollDeviceCode
  alias FluxVale.Identity.User

  @client "fluxvale-cli"
  @grant "urn:ietf:params:oauth:grant-type:device_code"

  describe "pending — the interval machine" do
    test "the first poll answers authorization_pending and records the counted poll" do
      {:ok, minted} = mint()

      assert {:ok, %{status: :authorization_pending}} =
               Identity.poll_device_code(@client, minted.device_code)

      {:ok, counted} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert counted.poll_count == 1
      assert %DateTime{} = counted.last_polled_at
    end

    test "a poll sooner than the interval answers slow_down and stamps nothing" do
      {:ok, minted} = mint()

      assert {:ok, %{status: :authorization_pending}} =
               Identity.poll_device_code(@client, minted.device_code)

      {:ok, counted} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      # One second inside the 5-second interval.
      assert {:error, :slow_down} =
               Identity.poll_device_code(@client, minted.device_code,
                 now: DateTime.add(counted.last_polled_at, 4, :second)
               )

      # The refusal is not a counted poll: the stamp did not move.
      {:ok, untouched} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert untouched.poll_count == 1
    end

    test "a poll after the interval answers authorization_pending again" do
      {:ok, minted} = mint()

      assert {:ok, %{status: :authorization_pending}} =
               Identity.poll_device_code(@client, minted.device_code)

      {:ok, counted} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      assert {:ok, %{status: :authorization_pending}} =
               Identity.poll_device_code(@client, minted.device_code,
                 now: DateTime.add(counted.last_polled_at, 5, :second)
               )

      {:ok, recounted} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert recounted.poll_count == 2
    end

    test "the first poll is never slow_down (nothing stamped yet)" do
      {:ok, minted} = mint()

      assert {:ok, %{status: :authorization_pending}} =
               Identity.poll_device_code(@client, minted.device_code,
                 now: ~U[2020-01-01T00:00:00Z]
               )
    end
  end

  describe "approved — the one-time grant" do
    test "the poll mints the PAT for the approver, carries provenance, consumes the row" do
      approver = User.create!("device-grant@fluxvale.com", %{}, authorize?: false)
      {:ok, minted} = mint(scopes: ["instances:read", "wallet:read"])

      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)

      before = DateTime.utc_now()

      assert {:ok, %{token: raw, pat: pat, expires_in: expires_in}} =
               Identity.poll_device_code(@client, minted.device_code)

      # The raw fvpat_ value, delivered once.
      assert raw =~ ~r/^fvpat_[A-Za-z0-9_-]{43}$/

      # Minted FOR the approver — the clicking user, per the
      # :approve action's contract.
      assert pat.user_id == approver.id
      assert pat.scopes == ["instances:read", "wallet:read"]
      assert pat.name == "CLI sign-in"

      # The provenance record rides the metadata map (OQ #9's
      # "extra_data/claims" intent — self-describing).
      assert pat.metadata == %{
               "client_id" => @client,
               "grant_type" => "device_flow",
               "scopes" => ["instances:read", "wallet:read"],
               "minted_via" => "device"
             }

      # expires_in is the PAT's remaining seconds (~1 year).
      assert expires_in == DateTime.diff(pat.expires_at, before, :second)
      assert expires_in > 365 * 24 * 60 * 60 - 60

      {:ok, granted_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert granted_row.status == :consumed
    end

    test "the token value never lands in a log line" do
      approver = User.create!("device-grant-log@fluxvale.com", %{}, authorize?: false)
      {:ok, minted} = mint()

      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)

      # The suite runs at :warning — open the level for the capture
      # and restore immediately (this module runs exclusively, so no
      # async capture can be mid-window when the level closes).
      previous = Logger.level()
      Logger.configure(level: :info)

      {result, log} =
        with_log(fn -> Identity.poll_device_code(@client, minted.device_code) end)

      Logger.configure(level: previous)

      assert {:ok, %{token: raw}} = result
      assert log =~ "device flow token issued"
      refute log =~ raw
      refute log =~ "fvpat_"
      # The poll path logs outcomes, never codes.
      refute log =~ minted.user_code
    end

    test "a second poll answers expired_token — the wire crosses once" do
      approver = User.create!("device-grant-once@fluxvale.com", %{}, authorize?: false)
      {:ok, minted} = mint()

      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)

      assert {:ok, %{token: _raw}} = Identity.poll_device_code(@client, minted.device_code)

      # Even one interval later — the row is consumed, not rate-limited.
      assert {:error, :expired_token} =
               Identity.poll_device_code(@client, minted.device_code,
                 now: DateTime.add(DateTime.utc_now(), 60, :second)
               )

      assert {:error, :expired_token} = Identity.poll_device_code(@client, minted.device_code)
    end

    test "an approved row grants regardless of poll timing (slow_down is a pending state)" do
      approver = User.create!("device-grant-fast@fluxvale.com", %{}, authorize?: false)
      {:ok, minted} = mint()

      # Count a poll first, then approve, then poll again immediately.
      assert {:ok, %{status: :authorization_pending}} =
               Identity.poll_device_code(@client, minted.device_code)

      {:ok, counted} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(counted, approver.id, actor: approver)

      assert {:ok, %{token: _raw}} = Identity.poll_device_code(@client, minted.device_code)
    end
  end

  describe "the refusal states" do
    test "a denied row answers access_denied" do
      approver = User.create!("device-denied-poll@fluxvale.com", %{}, authorize?: false)
      {:ok, minted} = mint()

      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _denied} = DeviceCode.deny(pending_row, actor: approver)

      assert {:error, :access_denied} = Identity.poll_device_code(@client, minted.device_code)
    end

    test "a row past expires_at answers expired_token (expiry rides the timestamp)" do
      # Seed-only state: already past expiry at creation — no action
      # produces it (expires_at is mint-stamped, never accepted on
      # update).
      Ash.Seed.seed!(DeviceCode, %{
        id: Ash.UUIDv7.generate(),
        device_code: "expired-code-000000000000000000000000000000000000000",
        user_code: "EXPR-ROW1",
        client_id: @client,
        scopes: [],
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second),
        poll_count: 0
      })

      assert {:error, :expired_token} =
               Identity.poll_device_code(
                 @client,
                 "expired-code-000000000000000000000000000000000000000"
               )
    end

    test "an unknown device_code answers expired_token (no existence oracle)" do
      assert {:error, :expired_token} =
               Identity.poll_device_code(@client, "unknown-code-0000000000000000000000")
    end

    test "a nil device_code answers expired_token" do
      assert {:error, :expired_token} = Identity.poll_device_code(@client, nil)
    end
  end

  describe "the client gate" do
    test "an unknown client is refused before any row is consulted" do
      {:ok, minted} = mint()

      assert {:error, {:invalid_client, "someone-else"}} =
               Identity.poll_device_code("someone-else", minted.device_code)

      assert {:error, {:invalid_client, nil}} = Identity.poll_device_code(nil, minted.device_code)
    end
  end

  describe "grant_type/0" do
    test "is the RFC 8628 grant constant (the controller's one tie)" do
      assert PollDeviceCode.grant_type() == @grant
    end
  end

  defp mint(overrides \\ []) do
    scopes = Keyword.get(overrides, :scopes, [])

    assert {:ok, row} = Identity.mint_device_code(%{client_id: @client, scopes: scopes})
    {:ok, row}
  end
end

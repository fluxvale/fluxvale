defmodule FluxVale.Identity.Operations.MintDeviceCodeTest do
  @moduledoc false

  # #362 T3: the device-flow mint — the RFC 8628 §3.1 payload's
  # server half. The wire constants (43-char device_code, XXXX-XXXX
  # user_code, 10-minute TTL), the two gates (client, catalog), and
  # the resource-level second door live here.

  use FluxVale.DataCase, async: true

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Invalid
  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.Operations.MintDeviceCode
  alias FluxVale.Identity.User

  @client "fluxvale-cli"

  describe "call/2 — the mint" do
    test "mints a pending row with the wire's shape" do
      before = DateTime.utc_now()

      assert {:ok, row} =
               Identity.mint_device_code(%{client_id: @client, scopes: ["instances:read"]})

      # 43 url-safe chars of 32 random bytes (the PAT random's shape).
      assert row.device_code =~ ~r/^[A-Za-z0-9_-]{43}$/

      # The human-typed code: XXXX-XXXX over the no-confusables
      # alphabet (no I/L/O/0/1).
      assert row.user_code =~ ~r/^[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}$/

      assert row.client_id == @client
      assert row.scopes == ["instances:read"]
      assert row.status == :pending
      assert row.user_id == nil
      assert row.poll_count == 0
      assert row.last_polled_at == nil

      # 10 minutes out, second precision.
      assert_in_delta DateTime.diff(row.expires_at, before), 600, 2
      assert row.expires_at == DateTime.truncate(row.expires_at, :second)
    end

    test "empty scopes mint (OQ #9's full-access first-party shape)" do
      assert {:ok, row} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      assert row.scopes == []
    end

    test "ttl_seconds/0 and the stamped expires_at agree" do
      # One tie: the operation stamps from the resource's constant and
      # the endpoint echoes the same value as expires_in — a change to
      # either side moves both (AuthCode's ttl_minutes posture).
      before = DateTime.utc_now()

      assert {:ok, row} = Identity.mint_device_code(%{client_id: @client, scopes: []})

      assert_in_delta DateTime.diff(row.expires_at, before),
                      DeviceCode.ttl_seconds(),
                      2
    end
  end

  describe "call/2 — the gates" do
    test "an unknown client is refused before anything is created" do
      assert {:error, {:invalid_client, "not-the-cli"}} =
               Identity.mint_device_code(%{client_id: "not-the-cli", scopes: []})

      assert {:error, {:invalid_client, nil}} =
               Identity.mint_device_code(%{client_id: nil, scopes: []})

      assert [] = DeviceCode.pending!(actor: nil, authorize?: false)
    end

    test "off-catalog and duplicate scopes are refused" do
      assert {:error, {:invalid_scope, "wallet:write"}} =
               Identity.mint_device_code(%{client_id: @client, scopes: ["wallet:write"]})

      assert {:error, {:duplicate_scope, "instances:read"}} =
               Identity.mint_device_code(%{
                 client_id: @client,
                 scopes: ["instances:read", "instances:read"]
               })
    end
  end

  describe "the resource-level second door" do
    # The operation validates first; the resource validations stop a
    # caller that bypasses it (the PAT mint's posture, verbatim).
    test "a direct create with an off-catalog scope is invalid" do
      changeset = changeset(scopes: ["instances:admin"])

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
    end

    test "a direct create with a duplicate scope is invalid" do
      changeset = changeset(scopes: ["instances:read", "instances:read"])

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
    end

    test "a direct create with an unknown client is invalid" do
      changeset = changeset(client_id: "someone-elses-client")

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
    end
  end

  describe "the policy posture" do
    test "the mint path is system-side — no actor can create one under authorization" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.mint_device_code(%{client_id: @client, scopes: []}, authorize?: true)
    end

    test "no actor reads the row lookups — the endpoints pass authorize?: false" do
      {:ok, row} = Identity.mint_device_code(%{client_id: @client, scopes: []})

      assert {:error, %Ash.Error.Forbidden{}} =
               DeviceCode.get_by_device_code(row.device_code, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               DeviceCode.get_by_user_code(row.user_code, authorize?: true)
    end

    test "a signed-in user reads the pending list (the approval panel)" do
      user = User.create!("device-panel@fluxvale.com", %{}, authorize?: false)

      {:ok, _row} = Identity.mint_device_code(%{client_id: @client, scopes: []})

      assert [pending_row] = DeviceCode.pending!(actor: user)

      # The panel's shape — user_code, client, scopes, expiry; the
      # device_code is not the panel's business (it renders neither).
      assert %DeviceCode{} = pending_row
      assert pending_row.status == :pending
    end

    test "no actor cannot read the pending list" do
      {:ok, _row} = Identity.mint_device_code(%{client_id: @client, scopes: []})

      assert {:error, %Ash.Error.Forbidden{}} = DeviceCode.pending(actor: nil)
    end

    test "a non-pending row is invisible to the pending read" do
      user = User.create!("device-panel-gone@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _denied} = DeviceCode.deny(pending_row, actor: user)

      assert [] = DeviceCode.pending!(actor: user)
    end

    test "an expired pending row is invisible to the pending read (expiry rides the timestamp)" do
      user = User.create!("device-panel-expired@fluxvale.com", %{}, authorize?: false)

      # Ash.seed!-shaped precondition: a state no action produces
      # (already past expiry at mint) — AGENTS' sanctioned shape.
      attrs = %{
        device_code: "expired-pending-code-000000000000000000000000",
        user_code: "EXPR-PCOD",
        client_id: @client,
        scopes: [],
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      }

      changeset = Ash.Changeset.for_create(DeviceCode, :create, attrs, authorize?: false)

      _expired = Ash.create!(changeset)

      assert [] = DeviceCode.pending!(actor: user)
    end
  end

  describe "the approval actions" do
    test "approve binds the row to the passed user (the clicking actor)" do
      approver = User.create!("device-approver@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: ["wallet:read"]})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      assert {:ok, approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)
      assert approved.status == :approved
      assert approved.user_id == approver.id
    end

    test "a second approve is refused (the guard: still-pending only)" do
      approver = User.create!("device-approve-twice@fluxvale.com", %{}, authorize?: false)
      other = User.create!("device-approve-other@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)

      {:ok, current} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = DeviceCode.approve(current, other.id, actor: other)
    end

    test "deny flips a pending row; a denied row cannot approve" do
      denier = User.create!("device-denier@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      {:ok, denied} = DeviceCode.deny(pending_row, actor: denier)
      assert denied.status == :denied
      assert denied.user_id == nil

      assert {:error, %Ash.Error.Invalid{}} =
               DeviceCode.approve(denied, denier.id, actor: denier)
    end

    test "consume flips only an approved row; the approved row before it is untouched" do
      approver = User.create!("device-consumer@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      # Not yet approved: consume refuses.
      assert {:error, %Ash.Error.Invalid{}} =
               DeviceCode.consume(pending_row, authorize?: false)

      {:ok, _approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)
      {:ok, approved} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      assert {:ok, consumed} = DeviceCode.consume(approved, authorize?: false)
      assert consumed.status == :consumed

      # Idempotence by guard: a second consume refuses.
      assert {:error, %Ash.Error.Invalid{}} = DeviceCode.consume(consumed, authorize?: false)
    end

    test "approve without an actor is forbidden" do
      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               DeviceCode.approve(pending_row, "00000000-0000-4000-8000-000000000000", actor: nil)
    end
  end

  describe "touch_poll" do
    test "stamps last_polled_at and bumps poll_count" do
      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert pending_row.poll_count == 0
      assert pending_row.last_polled_at == nil

      assert {:ok, touched} = DeviceCode.touch_poll(pending_row, authorize?: false)
      assert touched.poll_count == 1
      assert %DateTime{} = touched.last_polled_at

      assert {:ok, again} = DeviceCode.touch_poll(touched, authorize?: false)
      assert again.poll_count == 2
    end

    test "a non-actor caller is forbidden (system-only — endpoints pass authorize?: false)" do
      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} = DeviceCode.touch_poll(pending_row)
    end
  end

  describe "get_by_user_code" do
    test "resolves a pending row by its user_code" do
      {:ok, row} = Identity.mint_device_code(%{client_id: @client, scopes: ["catalog:read"]})

      assert {:ok, found} = DeviceCode.get_by_user_code(row.user_code, authorize?: false)
      assert found.id == row.id
      assert found.scopes == ["catalog:read"]

      assert {:error, _not_found} =
               DeviceCode.get_by_user_code("NOPE-CODE", authorize?: false)
    end
  end

  describe "the user_code collision matcher" do
    # The retry loop's matcher, tested directly: the DB's
    # unique-violation shape (probed once, pinned here) versus every
    # other error the mint can surface. Forcing an actual collision
    # draw is a 1-in-32^8 event — the recursion itself carries the
    # coveralls-ignore.
    test "matches the user_code unique violation; refuses every other shape" do
      violation = %Invalid{
        errors: [%InvalidAttribute{field: :user_code, message: "has already been taken"}]
      }

      assert MintDeviceCode.user_code_taken?(violation)

      # Another field's unique violation is not ours.
      other_field = %Invalid{
        errors: [%InvalidAttribute{field: :device_code, message: "has already been taken"}]
      }

      refute MintDeviceCode.user_code_taken?(other_field)

      # A different error class entirely (DB outage, invalid input).
      empty = struct(Invalid)
      refute MintDeviceCode.user_code_taken?(empty)
      refute MintDeviceCode.user_code_taken?(:timeout)
    end
  end

  defp changeset(overrides) do
    suffix = System.unique_integer([:positive])

    base = %{
      device_code: "second-door-#{suffix}-00000000000000000000000",
      user_code: "SEC-#{String.pad_leading(Integer.to_string(rem(suffix, 1000)), 4, "0")}",
      client_id: @client,
      scopes: [],
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    }

    Ash.Changeset.for_create(DeviceCode, :create, Map.merge(base, Map.new(overrides)))
  end
end

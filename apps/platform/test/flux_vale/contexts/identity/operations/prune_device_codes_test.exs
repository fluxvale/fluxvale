defmodule FluxVale.Identity.Operations.PruneDeviceCodesTest do
  @moduledoc false

  # #362 T3: the device-code sweep — dead rows past the retention
  # horizon go; anything that can still answer a poll stays.

  use FluxVale.DataCase, async: true

  import Ecto.Query

  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.User

  @client "fluxvale-cli"

  describe "call/1" do
    test "deletes rows past expires_at beyond the horizon, keeps fresh ones" do
      # Seed-only states: backdated stamps no action produces.
      Ash.Seed.seed!(DeviceCode, %{
        id: Ash.UUIDv7.generate(),
        device_code: "prune-old-expired-000000000000000000000000000000",
        user_code: "PRUN-OLD1",
        client_id: @client,
        scopes: [],
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(), -2, :day),
        poll_count: 0
      })

      Ash.Seed.seed!(DeviceCode, %{
        id: Ash.UUIDv7.generate(),
        device_code: "prune-fresh-pending-000000000000000000000000000",
        user_code: "PRUN-NEW1",
        client_id: @client,
        scopes: [],
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
        poll_count: 0
      })

      assert {:ok, 1} = Identity.prune_device_codes(authorize?: false)

      # Only the fresh row survives the sweep (the :pending read —
      # there is no primary read on this resource, every read is
      # named).
      assert [%DeviceCode{} = kept] = DeviceCode.pending!(actor: nil, authorize?: false)
      assert kept.user_code == "PRUN-NEW1"
    end

    test "a freshly consumed row survives (it can still answer a poll for a day)" do
      approver = User.create!("prune-consumer@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)
      {:ok, approved} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _consumed} = DeviceCode.consume(approved, authorize?: false)

      assert {:ok, 0} = Identity.prune_device_codes(authorize?: false)

      assert {:ok, _row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
    end

    test "a consumed row past the horizon goes" do
      approver = User.create!("prune-consumed-old@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)
      {:ok, approved} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, consumed} = DeviceCode.consume(approved, authorize?: false)

      backdate_row!(consumed)

      assert {:ok, 1} = Identity.prune_device_codes(authorize?: false)

      assert {:error, _gone} =
               DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
    end

    test "a denied row past the horizon goes too (terminal-dead, same sweep)" do
      approver = User.create!("prune-denier@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _denied} = DeviceCode.deny(pending_row, actor: approver)

      backdate_row!(pending_row)

      assert {:ok, 1} = Identity.prune_device_codes(authorize?: false)
    end
  end

  # A state no action can produce: updated_at is a timestamp Ash
  # manages. Direct Ecto write on the schema, the Ash.Seed posture
  # (AGENTS: states actions can't produce).
  defp backdate_row!(row) do
    query = from(dc in "device_codes", where: dc.id == type(^row.id, Ecto.UUID))

    FluxVale.Repo.update_all(query,
      set: [updated_at: DateTime.add(DateTime.utc_now(), -2, :day)]
    )
  end
end

defmodule FluxVale.Janitor.PruneDeviceCodesTest do
  @moduledoc false

  # #362 T3: the cron-triggered entry point — the business logic is
  # Identity.prune_device_codes/1 (own suite next door).

  use FluxVale.DataCase, async: true

  import Ecto.Query

  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.User
  alias FluxVale.Janitor.PruneDeviceCodes
  alias FluxVale.Repo

  @client "fluxvale-cli"

  describe "perform/1" do
    test "sweeps dead device codes through the Identity domain seam" do
      approver = User.create!("janitor-devices@fluxvale.com", %{}, authorize?: false)

      {:ok, minted} = Identity.mint_device_code(%{client_id: @client, scopes: []})
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, approver.id, actor: approver)
      {:ok, approved} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, consumed} = DeviceCode.consume(approved, authorize?: false)

      # Seed-only backdate: past the retention horizon (the operation's
      # suite covers the boundary; this exercises the job plumbing).
      query = from(dc in "device_codes", where: dc.id == type(^consumed.id, Ecto.UUID))

      Repo.update_all(query, set: [updated_at: DateTime.add(DateTime.utc_now(), -2, :day)])

      assert {:ok, 1} = PruneDeviceCodes.perform(%Oban.Job{})

      gone? = from(dc in "device_codes", where: dc.id == type(^consumed.id, Ecto.UUID))
      assert Repo.exists?(gone?) == false
    end
  end
end

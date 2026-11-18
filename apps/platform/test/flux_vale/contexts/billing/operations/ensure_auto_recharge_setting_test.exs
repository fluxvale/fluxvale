defmodule FluxVale.Billing.Operations.EnsureAutoRechargeSettingTest do
  @moduledoc "Setting provisioning (#829 L3): idempotent get-or-create."

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.TestSupport.BillingFixtures

  test "creates a setting for an org that has none" do
    {org, _owner} = BillingFixtures.grant_free_org!()

    assert {:ok, setting} = Billing.ensure_auto_recharge_setting(org)
    assert setting.organization_id == org.id
    # The launch default: the row exists inertly until the owner opts in.
    assert setting.mode == :off
  end

  test "is idempotent — the same row comes back" do
    {org, _owner} = BillingFixtures.grant_free_org!()

    {:ok, setting} = Billing.ensure_auto_recharge_setting(org)
    {:ok, again} = Billing.ensure_auto_recharge_setting(org)

    assert again.id == setting.id
  end
end

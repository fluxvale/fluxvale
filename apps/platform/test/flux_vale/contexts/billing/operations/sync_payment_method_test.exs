defmodule FluxVale.Billing.Operations.SyncPaymentMethodTest do
  @moduledoc """
  The billing card's mount-time method sync (#829 S5): the poll IS the
  sync (Polar has no method-attached webhook) — count > 0 attaches, 0
  un-attaches, a provider fault leaves the stored state untouched, a
  row without a provider customer asks nothing, and the gate off
  refuses. Provider legs ride Mimic; NO live Polar call exists in this
  lane.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Billing
  alias FluxVale.Billing.Providers.Polar
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    # The gate rides a stub, never app-env mutation — async suites
    # share the node's env (the S4 sweep's posture).
    stub(Billing, :auto_recharge_charge_mode?, fn -> true end)

    {org, _owner} = BillingFixtures.grant_free_org!()
    {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

    %{org: org, setting: setting}
  end

  # System write — :set_method_status is actor-forbidden by policy;
  # the test drives it the way the production seam does.
  defp link_customer!(setting, customer_id \\ "cust_test") do
    setting
    |> Ash.Changeset.for_update(:set_method_status, %{
      payment_method_status: :none,
      provider_customer_id: customer_id
    })
    |> Ash.update!(authorize?: false)
  end

  defp attach_method!(setting, customer_id \\ "cust_test") do
    setting
    |> Ash.Changeset.for_update(:set_method_status, %{
      payment_method_status: :attached,
      provider_customer_id: customer_id
    })
    |> Ash.update!(authorize?: false)
  end

  test "the gate off refuses", %{setting: setting} do
    stub(Billing, :auto_recharge_charge_mode?, fn -> false end)

    stub(Polar, :list_payment_methods, fn _id ->
      flunk("no provider call with the gate off")
    end)

    assert {:error, :charge_mode_off} = Billing.sync_payment_method(setting)
  end

  test "a row without a provider customer asks nothing", %{setting: setting} do
    stub(Polar, :list_payment_methods, fn _id ->
      flunk("nothing to ask the provider — no customer stored")
    end)

    assert {:ok, :no_customer, ^setting} = Billing.sync_payment_method(setting)
  end

  test "count > 0 attaches", %{org: org, setting: setting} do
    setting = link_customer!(setting)
    stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

    assert {:ok, :attached, fresh} = Billing.sync_payment_method(setting)
    assert fresh.payment_method_status == :attached

    assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
    assert persisted.payment_method_status == :attached
  end

  test "the provider agreeing with the stored status skips the write (no version-row churn)", %{
    setting: setting
  } do
    # The stored row already says :attached and the provider agrees —
    # the short-circuit returns the row unwritten (the pinned binding
    # proves no new struct came out of a write path).
    setting = attach_method!(setting)
    stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

    assert {:ok, :attached, ^setting} = Billing.sync_payment_method(setting)
  end

  test "count 0 un-attaches (a method removed in the portal)", %{org: org, setting: setting} do
    setting = attach_method!(setting)

    stub(Polar, :list_payment_methods, fn _id -> {:ok, 0, nil} end)

    assert {:ok, :none, fresh} = Billing.sync_payment_method(setting)
    assert fresh.payment_method_status == :none

    assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
    assert persisted.payment_method_status == :none
  end

  test "a provider fault leaves the stored state untouched (the next mount retries)", %{
    org: org,
    setting: setting
  } do
    setting =
      setting
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :attached,
        provider_customer_id: "cust_test"
      })
      |> Ash.update!(authorize?: false)

    stub(Polar, :list_payment_methods, fn _id -> {:error, :network_error} end)

    assert {:error, :network_error} = Billing.sync_payment_method(setting)

    assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
    assert persisted.payment_method_status == :attached
  end

  test "a failed status write rides back as the error (the stored state stands)", %{
    org: org,
    setting: setting
  } do
    # The provider answered :attached; the status write dies at the DB
    # (forced at the Ash.update seam — the S3 crash-tests' stance). The
    # fault rides back and the stored :none stands.
    setting = link_customer!(setting)
    stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)
    stub(Ash, :update, fn _changeset, _opts -> {:error, :db_hiccup} end)

    assert {:error, :db_hiccup} = Billing.sync_payment_method(setting)

    assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
    assert persisted.payment_method_status == :none
  end
end

defmodule FluxVale.Billing.Operations.OpenBillingSessionTest do
  @moduledoc """
  The "Add payment method" click's seam (#829 S5): the request carries
  the owner's primary verified email and the SETTING'S evidence
  address, the customer reference persists with the status staying
  :none (a customer is not a method), the portal URL comes back fresh
  — and the gate off / a missing country refuse before any provider
  call. Provider legs ride Mimic canaries (the topup_org_test stance);
  NO live Polar call exists in this lane.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Billing
  alias FluxVale.Billing.Providers.Polar
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    # The gate rides a stub, never app-env mutation — async suites
    # share the node's env (the S4 sweep's posture).
    stub(Billing, :auto_recharge_charge_mode?, fn -> true end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

    %{
      org: org,
      owner: owner,
      setting: setting,
      owner_email: AccountsFixtures.primary_address!(owner)
    }
  end

  test "the gate off refuses before any provider call", %{
    org: org,
    setting: setting,
    owner: owner
  } do
    stub(Billing, :auto_recharge_charge_mode?, fn -> false end)

    stub(Polar, :create_billing_session, fn _request, _opts ->
      flunk("no provider call with the gate off")
    end)

    assert {:error, :charge_mode_off} = Billing.open_billing_session(org, setting, owner)
  end

  test "a missing billing country refuses before any provider call", %{
    org: org,
    setting: setting,
    owner: owner
  } do
    stub(Polar, :create_billing_session, fn _request, _opts ->
      flunk("no provider call without the evidence country")
    end)

    assert {:error, :billing_country_missing} = Billing.open_billing_session(org, setting, owner)
  end

  test "the request carries the owner's email and the setting's address; the URL comes back fresh",
       %{
         org: org,
         setting: setting,
         owner: owner,
         owner_email: owner_email
       } do
    # Rebind: the seam reads the row it's handed — the in-memory copy
    # must carry the saved evidence (the stale-struct trap, S2's
    # moduledoc).
    {:ok, setting} =
      Billing.set_auto_recharge_setting(
        setting,
        %{billing_country: "US", billing_state: "CA"},
        actor: owner
      )

    parent = self()

    stub(Polar, :create_billing_session, fn request, _opts ->
      send(parent, {:session_request, request})
      {:ok, %{customer_id: "cust_1", portal_url: "https://portal.example/one-time"}}
    end)

    assert {:ok, "https://portal.example/one-time"} =
             Billing.open_billing_session(org, setting, owner)

    assert_received {:session_request, request}
    assert request.email == owner_email
    assert request.organization_id == org.id
    assert request.billing_address == %{country: "US", state: "CA"}

    # The customer reference persisted; the status stays :none — a
    # customer is not a method (the mount sync answers that).
    assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
    assert persisted.provider_customer_id == "cust_1"
    assert persisted.payment_method_status == :none
  end

  test "an owner with no verified address refuses (data drift — actions always stamp one)", %{
    org: org,
    setting: setting
  } do
    # Ash.Seed.seed! — the sanctioned escape: the User create action
    # JIT-writes the address row, and this test needs an account
    # WITHOUT one (drift the actions cannot produce).
    drifter = Ash.Seed.seed!(FluxVale.Identity.User, %{username: "no-address-drifter"})

    stub(Polar, :create_billing_session, fn _request, _opts ->
      flunk("no provider call without the owner email")
    end)

    assert {:error, :owner_email_missing} = Billing.open_billing_session(org, setting, drifter)
  end

  test "a provider fault rides back as the error", %{org: org, setting: setting, owner: owner} do
    {:ok, setting} =
      Billing.set_auto_recharge_setting(setting, %{billing_country: "US"}, actor: owner)

    stub(Polar, :create_billing_session, fn _request, _opts ->
      {:error, :api_error}
    end)

    assert {:error, :api_error} = Billing.open_billing_session(org, setting, owner)

    # Nothing persisted on the fault.
    assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
    assert is_nil(persisted.provider_customer_id)
  end
end

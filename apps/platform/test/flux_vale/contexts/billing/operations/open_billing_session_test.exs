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

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
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
    org: _org,
    setting: _setting
  } do
    # Ash.Seed.seed! — the sanctioned escape: the User create action
    # JIT-writes the address row, and this test needs an account
    # WITHOUT one (drift the actions cannot produce). The drifter is
    # the org's OWNER here (a real membership) so the seam gets past
    # the ownership check and refuses on the missing address.
    drifter = Ash.Seed.seed!(FluxVale.Identity.User, %{username: "no-address-drifter"})

    org = Organization.create!(%{name: "Drift Org", slug: "drift-org"}, authorize?: false)

    Membership.create!(%{organization_id: org.id, user_id: drifter.id, role: :owner},
      authorize?: false
    )

    {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

    stub(Polar, :create_billing_session, fn _request, _opts ->
      flunk("no provider call without the owner email")
    end)

    assert {:error, :owner_email_missing} = Billing.open_billing_session(org, setting, drifter)
  end

  test "a non-owner is refused at the seam — no provider call", %{
    org: org,
    setting: setting
  } do
    # Ash.Seed.seed! — a plain user with NO membership in the org: the
    # LiveView's button gate is UX; the seam enforces owner-hood
    # itself (defense-in-depth, decision C's consent model).
    outsider = Ash.Seed.seed!(FluxVale.Identity.User, %{username: "portal-outsider"})

    stub(Polar, :create_billing_session, fn _request, _opts ->
      flunk("no provider call for a non-owner")
    end)

    assert {:error, :not_owner} = Billing.open_billing_session(org, setting, outsider)
  end

  test "a re-opened portal for the SAME customer preserves :attached", %{
    org: org,
    setting: setting,
    owner: owner
  } do
    {:ok, setting} =
      Billing.set_auto_recharge_setting(setting, %{billing_country: "US"}, actor: owner)

    # The method is attached on this very customer (the sync put it
    # there); the buyer re-opens the portal for a tweak.
    attached_row =
      setting
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :attached,
        provider_customer_id: "cust_same"
      })
      |> Ash.update!(authorize?: false)

    stub(Polar, :create_billing_session, fn _request, _opts ->
      {:ok, %{customer_id: "cust_same", portal_url: "https://portal.example/again"}}
    end)

    assert {:ok, "https://portal.example/again"} =
             Billing.open_billing_session(org, attached_row, owner)

    # The provider has not reported removal — the re-open never resets.
    assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
    assert persisted.payment_method_status == :attached
    assert persisted.provider_customer_id == "cust_same"
  end

  test "a changed customer reference resets to :none (newly linked customer)", %{
    org: org,
    setting: setting,
    owner: owner
  } do
    {:ok, with_country} =
      Billing.set_auto_recharge_setting(setting, %{billing_country: "US"}, actor: owner)

    attached_row =
      with_country
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :attached,
        provider_customer_id: "cust_old"
      })
      |> Ash.update!(authorize?: false)

    stub(Polar, :create_billing_session, fn _request, _opts ->
      {:ok, %{customer_id: "cust_new", portal_url: "https://portal.example/new"}}
    end)

    assert {:ok, "https://portal.example/new"} =
             Billing.open_billing_session(org, attached_row, owner)

    # A new customer has no method until the sync sees one.
    assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
    assert persisted.payment_method_status == :none
    assert persisted.provider_customer_id == "cust_new"
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

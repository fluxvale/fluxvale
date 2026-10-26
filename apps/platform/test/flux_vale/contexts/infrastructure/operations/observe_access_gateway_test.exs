defmodule FluxVale.Infrastructure.Operations.ObserveAccessGatewayTest do
  @moduledoc false

  # ADR-0039 §2's observed-state rule: gateway_status is the ONLY
  # promoter to :active, so the panel's badge can never claim a join the
  # cluster has not reported. These pin every transition, plus the two
  # arms that must NOT write (a suspension owns the row; provisioning is
  # still landing).

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures

  setup do
    stub(Tailscale, :provision_gateway, fn _gateway, _key -> {:ok, :provisioned} end)
    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)

    {org, _owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org}
  end

  describe "observed :active" do
    test "promotes :provisioning and arms the settlement anchor", %{org: org} do
      gateway = provisioned_row!(org)
      assert gateway.state == :provisioning
      assert gateway.metering_since == nil

      expect(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected to your tailnet"}}
      end)

      {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

      assert observed.state == :active
      # The first observation is what turns billing on (the settle
      # trigger's where is :active, and it needs an open window).
      assert observed.metering_since
    end

    test "an already-active gateway is left alone — one write, then no-op", %{org: org} do
      gateway = AccessFixtures.gateway!(org)
      assert gateway.state == :active
      anchor = gateway.metering_since

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected"}}
      end)

      {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

      assert observed.state == :active
      # The anchor is NOT reset — a re-observation must never reopen a
      # settlement window the settle trigger already owns.
      assert observed.metering_since == anchor
    end

    test "recovery from :needs_attention clears the attention clock", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected"}}
      end)

      {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

      assert observed.state == :active
      assert observed.needs_attention_since == nil
    end
  end

  describe "observed :needs_attention" do
    test "demotes an active gateway and stamps the clock once", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :needs_attention, message: "Not connected — check the access key"}}
      end)

      {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

      assert observed.state == :needs_attention
      assert observed.needs_attention_since
      assert observed.status_message =~ "access key"
    end

    test "a still-broken gateway does not restamp the clock", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)
      since = AccessGateway.get_by_id!(gateway.id, authorize?: false).needs_attention_since

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :needs_attention, message: "Still not connected"}}
      end)

      {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

      assert observed.needs_attention_since == since
    end
  end

  describe "arms that must not write" do
    # A suspended gateway observes as "not serving" (it is scaled to 0),
    # but the BALANCE decides that state — an observation must never
    # silently un-suspend a row the ladder parked.
    test "a suspension is never overridden by an observation", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :needs_attention, message: "Paused"}}
      end)

      {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

      assert observed.state == :suspended
    end

    test "observed :provisioning leaves the row as it is", %{org: org} do
      gateway = provisioned_row!(org)

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :provisioning, message: "Setting up access"}}
      end)

      {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

      assert observed.state == :provisioning
      assert observed.metering_since == nil
    end

    test "an observed :active on a suspended row still does not resume", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected"}}
      end)

      {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

      assert observed.state == :suspended
    end
  end

  describe "read failure" do
    test "a status read error surfaces without writing", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      stub(Tailscale, :gateway_status, fn _gateway -> {:error, :cluster_down} end)

      assert {:error, :cluster_down} = Infrastructure.observe_access_gateway(gateway)

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :active
    end
  end

  # A row that has its cluster objects but has not been observed yet.
  defp provisioned_row!(org) do
    AccessGateway.create!(
      %{organization_id: org.id, monthly_cents: 200, auth_key: "tskey"},
      authorize?: false
    )
  end
end

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
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

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

    test "an already-active gateway keeps its settlement anchor", %{org: org} do
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

  describe "an unchanged settled :active observation (D7)" do
    test "re-reads the committed row, writes nothing and broadcasts nothing", %{org: org} do
      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected to your tailnet"}}
      end)

      settled = settled_active_row!(org)
      settled_updated_at = settled.updated_at

      Phoenix.PubSub.subscribe(FluxVale.PubSub, "access_gateways:#{org.id}")

      assert {:ok, observed} = Infrastructure.observe_access_gateway(settled)

      # No UPDATE means no notification: Ash's PubSub notifier fires on
      # update, so a quiet observation cannot publish anything.
      refute_receive %Ash.Notifier.Notification{}, 200

      assert observed.updated_at == settled_updated_at
      assert observed.state == :active
      assert observed.status_message == "Connected to your tailnet"

      committed = AccessGateway.get_by_id!(settled.id, authorize?: false)
      assert committed.updated_at == settled_updated_at
    end

    test "a row missing one settled field still writes and broadcasts", %{org: org} do
      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected to your tailnet"}}
      end)

      settled = settled_active_row!(org)

      # The settled shape minus one anchor: the quiet arm must not fire.
      cleared =
        settled
        |> Ash.Changeset.for_update(:update_state, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:provisioned_at, nil)
        |> Ash.update!()

      assert is_nil(cleared.provisioned_at)

      Phoenix.PubSub.subscribe(FluxVale.PubSub, "access_gateways:#{org.id}")

      assert {:ok, observed} = Infrastructure.observe_access_gateway(cleared)

      assert_receive %Ash.Notifier.Notification{data: notified, action: %{name: :update_state}}
      assert notified.id == settled.id
      assert notified.provisioned_at
      assert observed.provisioned_at
      refute observed.updated_at == cleared.updated_at
    end

    test "a fall-through write does not rewind a settled anchor", %{org: org} do
      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected to your tailnet"}}
      end)

      settled = settled_active_row!(org)

      # A divergent committed row the observer will rewrite.
      diverged =
        settled
        |> Ash.Changeset.for_update(:update_state, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:provisioned_at, nil)
        |> Ash.update!()

      # The settle advance commits without changing state, so the state
      # filter cannot refuse it — the write must omit the held anchor.
      later = DateTime.add(diverged.metering_since, 3_600, :second)

      assert {:ok, _advanced} =
               diverged
               |> Ash.Changeset.for_update(:settle_anchors, %{metering_since: later},
                 authorize?: false
               )
               |> Ash.update()

      assert AccessGateway.get_by_id!(settled.id, authorize?: false).metering_since == later

      Phoenix.PubSub.subscribe(FluxVale.PubSub, "access_gateways:#{org.id}")

      # The passed struct still holds the pre-advance anchor.
      assert {:ok, observed} = Infrastructure.observe_access_gateway(diverged)

      assert_receive %Ash.Notifier.Notification{action: %{name: :update_state}}
      assert observed.state == :active

      # The committed advance survives the fall-through write.
      committed = AccessGateway.get_by_id!(settled.id, authorize?: false)
      assert committed.metering_since == later
    end

    test "the production trigger action is quiet too", %{org: org} do
      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected to your tailnet"}}
      end)

      settled = settled_active_row!(org)

      Phoenix.PubSub.subscribe(FluxVale.PubSub, "access_gateways:#{org.id}")

      # The trigger body, not the operation: Ash skips the data-layer
      # UPDATE when the changeset has no changes, so the empty
      # perform_observe action must leave the row untouched. This pins
      # that no future before_action resurrects the per-minute write.
      assert {:ok, observed} =
               AccessGateway.perform_observe(settled, %{}, authorize?: false)

      refute_receive %Ash.Notifier.Notification{}, 200
      assert observed.updated_at == settled.updated_at
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

  describe "a stale observation (P3-2)" do
    test "cannot resurrect a suspension committed after the read", %{org: org} do
      # The interleave: the observer holds an :active record, the ladder's
      # Suspend commits :suspended (anchor parked), then the observation
      # would land :active and REOPEN the anchor — a scaled-to-zero
      # gateway billing as active until the next hourly sweep.
      gateway = AccessFixtures.gateway!(org)
      stale = %{gateway | state: :active}
      assert stale.metering_since

      # Suspend commits behind the observer's back.
      expect(Tailscale, :scale_gateway, fn _gateway, 0 -> :ok end)
      {:ok, suspended} = AccessGateway.suspend(gateway, authorize?: false)
      assert suspended.state == :suspended
      assert suspended.metering_since == nil

      # The observer now reports the pod as still up (the read raced the
      # scale), deciding against the STALE :active record.
      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected"}}
      end)

      # It must not win: the write is state-filtered, so it is refused,
      # the observer re-reads, and the committed suspension is the
      # authority.
      assert {:ok, observed} = Infrastructure.observe_access_gateway(stale)

      assert observed.state == :suspended
      assert observed.metering_since == nil

      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert fresh.state == :suspended
      assert fresh.metering_since == nil
    end

    test "a stale write is refused rather than silently overwriting", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      # Bypass the observer's own re-decide to prove the write itself is
      # conditional: the changeset carries the state it decided against.
      stale = %{gateway | state: :provisioning}

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected"}}
      end)

      # The row is :active, the stale record says :provisioning, so the
      # filtered write is refused — StaleRecord — and the retry path
      # re-reads and succeeds against the committed row.
      assert {:ok, observed} = Infrastructure.observe_access_gateway(stale)
      assert observed.state == :active
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

  # The settled shape the observer lands: :active, both anchors armed, no
  # attention clock, the settled copy. Settled through the observer itself
  # (the only promoter to :active), read back from the committed row.
  defp settled_active_row!(org) do
    {:ok, settled} =
      org
      |> provisioned_row!()
      |> Infrastructure.observe_access_gateway()

    assert settled.state == :active
    assert settled.metering_since
    assert settled.provisioned_at
    assert settled.needs_attention_since == nil
    assert settled.status_message == "Connected to your tailnet"

    settled
  end

  # A row that has its cluster objects but has not been observed yet.
  defp provisioned_row!(org) do
    AccessGateway.create!(
      %{
        organization_id: org.id,
        monthly_cents: 200,
        tailnet_domain: "example.ts.net",
        auth_key: "tskey"
      },
      authorize?: false
    )
  end
end

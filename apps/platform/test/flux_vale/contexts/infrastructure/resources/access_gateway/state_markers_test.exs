defmodule FluxVale.Infrastructure.AccessGateway.StateMarkersTest do
  @moduledoc """
  The gateway billing-switch telemetry: one
  [:flux_vale, :gateway, :state_change] per real state change across
  the five state-writing actions — from/to decided AFTER the write
  (Suspend/Resume land their state in before_action hooks), the
  idempotent arms silent, and the observer's refused stale write
  never reaching after_action so its retry emits at most once.

  `async: false`: the events ride the global telemetry handler table
  (and Mimic is per-process anyway — the observe tests' stance).
  """

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.Telemetry

  @state_event [:flux_vale, :gateway, :state_change]

  setup do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)

    {org, _owner} = BillingFixtures.grant_free_org!()
    {:ok, org: org}
  end

  test "the observer's demotion emits from/to (:update_state funnel)", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    Telemetry.capture_events([@state_event])

    stub(Tailscale, :gateway_status, fn _gateway ->
      {:ok, %{state: :needs_attention, message: "Not connected — check the access key"}}
    end)

    {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

    assert observed.state == :needs_attention

    assert_receive {:telemetry_event, @state_event, %{count: 1},
                    %{from: :active, to: :needs_attention}}
  end

  test "the observer's same-state write is silent (an observation is always a write)", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    Telemetry.capture_events([@state_event])

    stub(Tailscale, :gateway_status, fn _gateway ->
      {:ok, %{state: :active, message: "Connected"}}
    end)

    {:ok, observed} = Infrastructure.observe_access_gateway(gateway)

    assert observed.state == :active

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
  end

  test "the ladder's suspend emits; the idempotent re-entry does not", %{org: org} do
    active = AccessFixtures.gateway!(org)
    Telemetry.capture_events([@state_event])

    {:ok, suspended} = AccessGateway.suspend(active, authorize?: false)

    assert suspended.state == :suspended

    assert_receive {:telemetry_event, @state_event, %{count: 1}, %{from: :active, to: :suspended}}

    # The ladder re-enters hourly while the balance stays ≤ 0: the
    # no-op arm writes nothing, and from == to emits nothing.
    {:ok, still} = AccessGateway.suspend(suspended, authorize?: false)

    assert still.state == :suspended

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
  end

  test "resume emits — the before_action force Suspend/Resume land after the change ran", %{
    org: org
  } do
    suspended = AccessFixtures.gateway!(org, state: :suspended)
    Telemetry.capture_events([@state_event])

    {:ok, resumed} = AccessGateway.resume(suspended, authorize?: false)

    assert resumed.state == :provisioning

    assert_receive {:telemetry_event, @state_event, %{count: 1},
                    %{from: :suspended, to: :provisioning}}
  end

  test "an error handler's landing emits (the change-fn mounts)", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    Telemetry.capture_events([@state_event])

    {:ok, errored} = AccessGateway.mark_teardown_error(gateway, %{error: %{}}, authorize?: false)

    assert errored.state == :destroying

    assert_receive {:telemetry_event, @state_event, %{count: 1},
                    %{from: :active, to: :destroying}}
  end

  # The observer's stale-record shape: the first (filter-refused) write
  # carries the transition but never reaches after_action — only the
  # re-read retry's successful write emits, so exactly one event lands.
  test "a refused stale write does not emit — the retry emits once", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    Telemetry.capture_events([@state_event])

    # The observer holds a :provisioning snapshot; the committed row is
    # :active, so the filtered write (:needs_attention, expected
    # :provisioning) is refused, the retry re-decides on the fresh row.
    stale = %{gateway | state: :provisioning}

    stub(Tailscale, :gateway_status, fn _gateway ->
      {:ok, %{state: :needs_attention, message: "Not connected"}}
    end)

    {:ok, observed} = Infrastructure.observe_access_gateway(stale)

    assert observed.state == :needs_attention

    assert_receive {:telemetry_event, @state_event, %{count: 1},
                    %{from: :active, to: :needs_attention}}

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
  end
end

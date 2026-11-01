defmodule FluxVale.Infrastructure.AccessGateway.StateMarkersTest do
  @moduledoc """
  The gateway billing-switch telemetry: one
  [:flux_vale, :gateway, :state_change] per real state change across
  the six mounted state-writing actions — from/to decided AFTER the
  write (Suspend/Resume/Repaste land their state in before_action
  hooks), the idempotent arms silent, the observer's refused stale
  write never reaching after_action so its retry emits at most once,
  and the token-drift claim's nested write suppressed so the
  after_transaction fallback is the one that counts.

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

  test "the re-paste's recovery edge emits — the occupancy alert reads the exit", %{
    org: org
  } do
    gateway = AccessFixtures.gateway!(org, state: :needs_attention)
    Telemetry.capture_events([@state_event])

    stub(Tailscale, :update_credential, fn _gateway, _key -> :ok end)

    {:ok, repasted} =
      AccessGateway.update_credential(gateway, %{auth_key: "tskey-new"}, authorize?: false)

    assert repasted.state == :provisioning

    assert_receive {:telemetry_event, @state_event, %{count: 1},
                    %{from: :needs_attention, to: :provisioning}}
  end

  test "a same-state re-paste (already :provisioning) stays silent", %{org: org} do
    gateway = AccessFixtures.gateway!(org, state: :provisioning)
    Telemetry.capture_events([@state_event])

    stub(Tailscale, :update_credential, fn _gateway, _key -> :ok end)

    {:ok, repasted} =
      AccessGateway.update_credential(gateway, %{auth_key: "tskey-new"}, authorize?: false)

    assert repasted.state == :provisioning

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
  end

  # The token-drift shape: the claim operation's nested drift write
  # carries the suppression context (its transaction is about to roll
  # back), then the caller's after_transaction fallback re-writes the
  # drift plainly — exactly one entry reaches the counter.
  test "a suppressed nested drift write is silent; the fallback's plain write emits once",
       %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    Telemetry.capture_events([@state_event])

    # The nested drift write (ClaimAccessDomain.drift_to_needs_attention/2's
    # shape): real state change, suppression flag set.
    {:ok, drifted} =
      AccessGateway.update_state(
        gateway,
        %{
          state: :needs_attention,
          status_message: "Tailscale rejected the API key",
          needs_attention_since: DateTime.utc_now()
        },
        context: %{suppress_state_markers: true},
        authorize?: false
      )

    assert drifted.state == :needs_attention

    refute_receive {:telemetry_event, _event, _measurements, _metadata}

    # The fallback (AccessDomain.Resume's after_transaction write): a
    # plain write of the same drift — the one that persists.
    {:ok, settled} =
      AccessGateway.update_state(
        gateway,
        %{state: :needs_attention, status_message: "Tailscale rejected the API key"},
        context: %{},
        authorize?: false
      )

    assert settled.state == :needs_attention

    assert_receive {:telemetry_event, @state_event, %{count: 1},
                    %{from: :active, to: :needs_attention}}

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
  end

  # The contract pin: the flag alone suppresses, on an ordinary
  # transition, whoever sets it — the nested-caller escape hatch.
  test "the suppression context alone suppresses a normal write", %{org: org} do
    gateway = AccessFixtures.gateway!(org)
    Telemetry.capture_events([@state_event])

    {:ok, suspended} =
      AccessGateway.update_state(
        gateway,
        %{state: :suspended, status_message: "Access paused"},
        context: %{suppress_state_markers: true},
        authorize?: false
      )

    assert suspended.state == :suspended

    refute_receive {:telemetry_event, _event, _measurements, _metadata}
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

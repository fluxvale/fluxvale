defmodule FluxVale.PromEx.Plugins.BusinessTest do
  @moduledoc """
  The fleet counter contract: three counters, the NARROWER fleet label
  sets (no app, no reason — the LiveDashboard tags deliberately
  dropped), the closed-enum derivations behind the 78-series ceiling,
  and an end-to-end scrape proving the events land as
  `flux_vale_*_total` series (the names the fleet allowlist and the
  alert rules query; nothing may rename them silently). Plus the #182
  stuck-in-error gauge: the poller's contract name and shape, the
  scoping that keeps zombies and undated rows out of the count, and
  the rendered series.
  """

  # async: false — the scrape starts the module-named PromEx tree,
  # which is VM-global (one instance of the named processes).
  use FluxVale.DataCase, async: false

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.StatusTransition
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.PromEx.Plugins.Business
  alias FluxVale.TestSupport.InstanceFixtures

  @series ~r/^flux_vale_(instance_status_transition|gateway_state_change|backup_run)_total\{/
  @gauge_line "flux_vale_instances_in_error "

  test "three counters over the narrower fleet label sets" do
    assert [%PromEx.MetricTypes.Event{metrics: counters}] =
             Business.event_metrics(otp_app: :flux_vale)

    assert length(counters) == 3

    by_name = Map.new(counters, fn counter -> {counter.name, counter} end)

    instance = Map.fetch!(by_name, [:flux_vale, :instance, :status_transition_total])
    gateway = Map.fetch!(by_name, [:flux_vale, :gateway, :state_change_total])
    backup = Map.fetch!(by_name, [:flux_vale, :backup, :run_total])

    assert instance.event_name == [:flux_vale, :instance, :status_transition]
    assert gateway.event_name == [:flux_vale, :gateway, :state_change]
    assert backup.event_name == [:flux_vale, :backup, :run]

    # Fleet labels are deliberately narrower than the emissions carry:
    # reason (instance) and the richer metadata stay dashboard-side.
    assert instance.tags == [:from, :to]
    assert gateway.tags == [:from, :to]
    assert backup.tags == [:kind, :status]

    Enum.each([instance, gateway, backup], fn counter ->
      assert counter.measurement == :count
    end)

    # Sum metrics, not counters — the zero-seed contract: a
    # Telemetry.Metrics counter counts events (+1 per emission, the
    # measurement ignored), which would inflate every series per
    # boot; sum accumulates the measurement, so count-1 events
    # accumulate identically and count-0 seeds materialize at 0.
    # The exporter still renders TYPE counter (sum's default).
    assert Enum.all?(counters, &match?(%Telemetry.Metrics.Sum{}, &1))
  end

  describe "the closed-enum derivations — the 78-series ceiling" do
    test "instance: the 52 legal pairs (validator table + catch-alls, from ≠ to)" do
      pairs = Business.instance_transition_pairs()

      assert length(pairs) == 52

      # Table edges (spot): the deploy funnel, the wake lane, the
      # re-deploy exit, error recovery.
      assert {:pending, :deploying} in pairs
      assert {:starting, :running} in pairs
      assert {:running, :sleeping} in pairs
      assert {:sleeping, :starting} in pairs
      assert {:error, :deploying} in pairs
      assert {:lost, :deploying} in pairs
      # #776: capacity waiting and stale-failure recovery.
      assert {:running, :no_capacity} in pairs
      assert {:no_capacity, :stopped} in pairs
      assert {:no_capacity, :starting} in pairs
      assert {:no_capacity, :running} in pairs
      assert {:no_capacity, :deleting} in pairs
      assert {:error, :running} in pairs

      # Catch-all arms: any → error / any → deleting, including
      # edges the table itself never lists.
      assert {:lost, :error} in pairs
      assert {:pending, :deleting} in pairs
      assert {:running, :deleting} in pairs

      # No self-edges (a no-op write emits nothing).
      refute {:error, :error} in pairs
      refute {:running, :running} in pairs

      # And every pair is legal per the validator itself.
      transitions = StatusTransition.valid_transitions()

      Enum.each(pairs, fn {from, to} ->
        legal = to in [:error, :deleting] or to in Map.fetch!(transitions, from)
        assert legal, "#{from} -> #{to} is not a validator-legal edge"
      end)
    end

    test "gateway: all 20 ordered from≠to pairs of the five-state enum" do
      assert Business.gateway_state_pairs() == [
               {:provisioning, :active},
               {:provisioning, :needs_attention},
               {:provisioning, :suspended},
               {:provisioning, :destroying},
               {:active, :provisioning},
               {:active, :needs_attention},
               {:active, :suspended},
               {:active, :destroying},
               {:needs_attention, :provisioning},
               {:needs_attention, :active},
               {:needs_attention, :suspended},
               {:needs_attention, :destroying},
               {:suspended, :provisioning},
               {:suspended, :active},
               {:suspended, :needs_attention},
               {:suspended, :destroying},
               {:destroying, :provisioning},
               {:destroying, :active},
               {:destroying, :needs_attention},
               {:destroying, :suspended}
             ]
    end

    test "backup: 3 kinds × 2 terminal statuses" do
      assert Business.backup_outcome_pairs() == [
               {:scheduled, :succeeded},
               {:scheduled, :failed},
               {:manual, :succeeded},
               {:manual, :failed},
               {:restore, :succeeded},
               {:restore, :failed}
             ]
    end
  end

  test "the business events land in the scrape as flux_vale_*_total series" do
    start_supervised!(FluxVale.PromEx)

    :telemetry.execute(
      [:flux_vale, :instance, :status_transition],
      %{count: 1},
      %{from: :deploying, to: :starting, reason: nil}
    )

    :telemetry.execute(
      [:flux_vale, :gateway, :state_change],
      %{count: 1},
      %{from: :active, to: :suspended}
    )

    :telemetry.execute(
      [:flux_vale, :backup, :run],
      %{count: 1, duration: 120.0},
      %{kind: :scheduled, status: :succeeded}
    )

    scrape = PromEx.get_metrics(FluxVale.PromEx)

    series_lines =
      scrape
      |> String.split("\n", trim: true)
      |> Enum.filter(&Regex.match?(@series, &1))

    # One labeled sample per family — and the dropped labels stay out:
    # the instance series carries from/to, never reason.
    assert length(series_lines) == 3

    assert scrape =~
             "flux_vale_instance_status_transition_total{from=\"deploying\",to=\"starting\"}"

    assert scrape =~ "flux_vale_gateway_state_change_total{from=\"active\",to=\"suspended\"}"
    assert scrape =~ "flux_vale_backup_run_total{kind=\"scheduled\",status=\"succeeded\"}"
    refute scrape =~ ~r/flux_vale_instance_status_transition_total\{[^}]*reason/

    # The exporter contract, pinned: a sum metric renders TYPE
    # counter (sum's PromEx default), and a count-1 event
    # accumulates to a sampled 1 — a reporter regression must fail
    # the suite, not silently break the numbers the zero-seed
    # exists to make countable.
    assert scrape =~ "# TYPE flux_vale_gateway_state_change_total counter"
    assert scrape =~ "flux_vale_gateway_state_change_total{from=\"active\",to=\"suspended\"} 1"

    # The naming contract, pinned from the other side: no PromEx-default
    # prefix leaks into a _total family, and the wake histograms never
    # match a _total glob — exactly the three business families exist.
    refute scrape =~ ~r/^flux_vale_prom_ex_.*_total\b/
    refute scrape =~ ~r/^flux_vale_wake_.*_total\b/
  end

  describe "the stuck-in-error gauge (infra #182)" do
    test "one polling group: 60s cadence, the contract name, a label-free last_value" do
      assert %PromEx.MetricTypes.Polling{} =
               group =
               Business.polling_metrics(otp_app: :flux_vale)

      assert group.group_name == :business_stuck_instances_polling_metrics
      assert group.poll_rate == 60_000

      # detach_on_error: false, pinned through its effect — build wraps
      # the measurement MFA in the safe runner, which rescues, logs, and
      # keeps polling. The default raw-MFA path lets telemetry_poller
      # permanently filter a raising measurement (its collect loop drops
      # any measurement that raised): one 60s tick during a transient DB
      # outage would kill the series for the pod's lifetime, and absent
      # reads 0 under the alert's `or vector(0)` stance — the exact
      # false-calm this gauge exists to eliminate.
      assert group.measurements_mfa == {
               PromEx.MetricTypes.Polling,
               :safe_polling_runner,
               [{Business, :execute_stuck_instances_metrics, []}]
             }

      assert [%Telemetry.Metrics.LastValue{} = gauge] = group.metrics
      assert gauge.name == [:flux_vale, :instances, :in_error]
      assert gauge.event_name == [:flux_vale, :instance, :in_error]
      assert gauge.measurement == :count

      # A gauge: no labels (the count is the alert's whole subject) and
      # no _total suffix (it is not a counter — the rendered name is
      # the cross-repo contract).
      assert gauge.tags == []

      # _total suffix check on the rendered name.
      rendered = Enum.join(gauge.name, "_")
      refute String.ends_with?(rendered, "_total")
    end

    test "recent_error_count scopes to status :error with an in-window stamp" do
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      # Delta assertions throughout: the gauge counts committed truth,
      # so pre-existing in-window :error rows from outside this sandbox
      # (probe debris in the persistent shared DB) would poison absolute
      # expectations — the deltas cancel any such baseline (#241's
      # lesson at the count seam, the concurrency tests' stance).
      before = Business.recent_error_count()

      # The counting shape: a fresh stuck row (the funnel's own entry
      # stamp — StatusMarkers set it on the :error write).
      stuck = stuck_instance!(version)
      assert Business.recent_error_count() == before + 1

      # The Oct-23 zombie shape: still :error, but the stamp is outside
      # the window. Counts nothing — a permanent zombie must never page.
      zombie = stuck_instance!(version)
      InstanceFixtures.pin!(zombie, errored_at: DateTime.add(DateTime.utc_now(), -8, :day))

      assert Business.recent_error_count() == before + 1

      # The undated shape: NULL errored_at (the pre-backfill rows).
      # NULL fails the window comparison — an unknown entry time must
      # not page.
      undated = stuck_instance!(version)
      InstanceFixtures.pin!(undated, errored_at: nil)

      assert Business.recent_error_count() == before + 1

      # The non-error shape: a recent stamp on a row that is not (or no
      # longer) in :error — the exit must have cleared it, and if a
      # regression ever leaves a stamp behind, the status arm still
      # keeps it out of the gauge.
      created = instance!(version)
      running = InstanceFixtures.walk_to!(created, :running)
      InstanceFixtures.pin!(running, errored_at: DateTime.utc_now())

      assert Business.recent_error_count() == before + 1

      # The exit itself: leaving :error (the recover edge) drops the
      # row from the gauge.
      {:ok, recovered} = InstanceK8s.update_status(stuck, :running, nil)

      assert is_nil(recovered.errored_at)
      assert Business.recent_error_count() == before
    end

    test "the poller's emission lands as the label-free flux_vale_instances_in_error gauge" do
      start_supervised!(FluxVale.PromEx)

      # Quiesce the boot collect before writing any sample: the poller
      # starts with init_delay 0 (telemetry_poller's default), so its
      # first collect fires immediately — in the poller process, OUTSIDE
      # this sandbox, reading committed truth only — and would otherwise
      # land a stale sample over ours at an arbitrary moment.
      # :sys.get_state suspends the gen_server only after its mailbox is
      # drained (the AGENTS' idiom); the boot sample is in, and the next
      # collect is a full 60s away — this test's own emissions are the
      # last writers from here on.
      poller_name = Module.safe_concat([FluxVale.PromEx, Poller, :"60000"])
      poller = Process.whereis(poller_name)
      assert poller != nil
      _state = :sys.get_state(poller)

      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      # Delta baseline, same debris-defense as the scoping test.
      before = Business.recent_error_count()

      # The gauge materializes at the baseline (each poll sample is the
      # whole truth — no seeding needed, unlike the counters).
      Business.execute_stuck_instances_metrics()

      empty_scrape = PromEx.get_metrics(FluxVale.PromEx)
      assert gauge_line(empty_scrape) == @gauge_line <> Integer.to_string(before)

      # One fresh stuck row (StatusMarkers stamped it on entry)…
      stuck_instance!(version)
      Business.execute_stuck_instances_metrics()

      scrape = PromEx.get_metrics(FluxVale.PromEx)

      assert gauge_line(scrape) == @gauge_line <> Integer.to_string(before + 1)
      # The exporter contract, pinned: a gauge, not a counter.
      assert scrape =~ "# TYPE flux_vale_instances_in_error gauge"
      # Label-free — no braces ever render on the sample line.
      refute scrape =~ @gauge_line <> "{"
    end
  end

  # A row freshly stuck in :error through the funnel — the entry stamp
  # is StatusMarkers' own write (the markers suite pins its semantics;
  # this suite consumes the shape).
  defp stuck_instance!(version) do
    created = instance!(version)
    starting = InstanceFixtures.walk_to!(created, :starting)

    {:ok, errored} =
      InstanceK8s.update_status(starting, :error, "rollout failed", :rollout_failed)

    errored
  end

  defp instance!(version) do
    Instance.create!(
      %{name: "Stuck #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
      actor: User.create!("stuck-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
    )
  end

  # The exact sample line ("name value"), skipping the TYPE comment.
  defp gauge_line(scrape) do
    scrape
    |> String.split("\n", trim: true)
    |> Enum.find(&String.starts_with?(&1, @gauge_line))
  end
end

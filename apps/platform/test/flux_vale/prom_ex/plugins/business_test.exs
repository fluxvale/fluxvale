defmodule FluxVale.PromEx.Plugins.BusinessTest do
  @moduledoc """
  The fleet counter contract: three counters, the NARROWER fleet label
  sets (no app, no reason — the LiveDashboard tags deliberately
  dropped), the closed-enum derivations behind the 68-series ceiling,
  and an end-to-end scrape proving the events land as
  `flux_vale_*_total` series (the names the fleet allowlist and the
  alert rules query; nothing may rename them silently).
  """

  # async: false — the scrape starts the module-named PromEx tree,
  # which is VM-global (one instance of the named processes).
  use FluxVale.DataCase, async: false

  alias FluxVale.Infrastructure.Instance.StatusTransition
  alias FluxVale.PromEx.Plugins.Business

  @series ~r/^flux_vale_(instance_status_transition|gateway_state_change|backup_run)_total\{/

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

  describe "the closed-enum derivations — the 68-series ceiling" do
    test "instance: the 42 legal pairs (validator table + catch-alls, from ≠ to)" do
      pairs = Business.instance_transition_pairs()

      assert length(pairs) == 42

      # Table edges (spot): the deploy funnel, the wake lane, the
      # re-deploy exit, error recovery.
      assert {:pending, :deploying} in pairs
      assert {:starting, :running} in pairs
      assert {:running, :sleeping} in pairs
      assert {:sleeping, :starting} in pairs
      assert {:error, :deploying} in pairs
      assert {:lost, :deploying} in pairs

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
end

defmodule FluxVale.PromEx.Plugins.BusinessTest do
  @moduledoc """
  The fleet counter contract: three counters, the NARROWER fleet label
  sets (no app, no reason — the LiveDashboard tags deliberately
  dropped), and an end-to-end scrape proving the events land as
  `flux_vale_*_total` series (the names the fleet allowlist and the
  alert rules query; nothing may rename them silently).
  """

  # async: false — the scrape starts the module-named PromEx tree,
  # which is VM-global (one instance of the named processes).
  use FluxVale.DataCase, async: false

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
  end
end

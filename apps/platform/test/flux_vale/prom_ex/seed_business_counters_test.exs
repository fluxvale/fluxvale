defmodule FluxVale.PromEx.SeedBusinessCountersTest do
  @moduledoc """
  The boot zero-seed: with no real event fired, all 68 closed-enum
  combos exist in the scrape at 0 — so increase() anchors on a zero
  sample and the first real event counts (the fleet occupancy rules'
  contract; a series' first increment is otherwise invisible).
  """

  # async: false — starts the module-named PromEx tree, which is
  # VM-global (one instance of the named processes).
  use FluxVale.DataCase, async: false

  alias FluxVale.PromEx.Plugins.Business
  alias FluxVale.PromEx.SeedBusinessCounters

  @zeroed ~r/^flux_vale_(instance_status_transition|gateway_state_change|backup_run)_total\{.*\} 0$/

  test "the boot child seeds all 68 combos at zero and exits cleanly" do
    start_supervised!(FluxVale.PromEx)

    seeder = start_supervised!(SeedBusinessCounters)

    # Temporary Task — wait for its clean exit before scraping (the
    # monitor-and-DOWN pattern, never sleeps).
    ref = Process.monitor(seeder)
    assert_receive {:DOWN, ^ref, :process, ^seeder, :normal}

    scrape = PromEx.get_metrics(FluxVale.PromEx)

    zeroed_lines =
      scrape
      |> String.split("\n", trim: true)
      |> Enum.filter(&Regex.match?(@zeroed, &1))

    # The ceiling, exactly: no more (a spurious combo would be a
    # permanent phantom series), no fewer (a missing one is the
    # deploy-blind edge this seeder exists to fix).
    assert length(zeroed_lines) == 68

    # Every combo by name — count alone could hide a dupe/miss pair.
    # The instance family carries from/to only (the fleet drops
    # reason; the seed's reason: nil matches the emitters' shape).
    Enum.each(Business.instance_transition_pairs(), fn {from, to} ->
      line = "flux_vale_instance_status_transition_total{from=\"#{from}\",to=\"#{to}\"}"

      assert scrape =~ "#{line} 0"
      refute scrape =~ "#{line} 1"
    end)

    Enum.each(Business.gateway_state_pairs(), fn {from, to} ->
      line = "flux_vale_gateway_state_change_total{from=\"#{from}\",to=\"#{to}\"}"

      assert scrape =~ "#{line} 0"
    end)

    Enum.each(Business.backup_outcome_pairs(), fn {kind, status} ->
      line = "flux_vale_backup_run_total{kind=\"#{kind}\",status=\"#{status}\"}"

      assert scrape =~ "#{line} 0"
    end)
  end

  # capture_log: :telemetry itself logs (and detaches) the rogue
  # handler — the expected failure-path [error], not a real one.
  @tag :capture_log
  test "a raising telemetry handler never crashes the seed" do
    # Boot safety, pinned: :telemetry detaches a failing handler and
    # never re-raises to the emitter, so the seed completes — the
    # untouched families' zeros land regardless of the rogue.
    :telemetry.attach(
      "seed-raise",
      [:flux_vale, :backup, :run],
      fn _event, _measurements, _metadata, _config -> raise "boom" end,
      []
    )

    on_exit(fn -> :telemetry.detach("seed-raise") end)

    start_supervised!(FluxVale.PromEx)

    assert :ok = SeedBusinessCounters.run()

    # The untouched families seeded fine.
    scrape = PromEx.get_metrics(FluxVale.PromEx)

    assert scrape =~ "flux_vale_gateway_state_change_total{from=\"active\",to=\"suspended\"}"
  end
end

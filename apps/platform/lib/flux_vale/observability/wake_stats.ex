defmodule FluxVale.Observability.WakeStats do
  @moduledoc """
  Per-app wake-time estimates derived from the live metric (#232) —
  the catalog badge's data source.

  Reads the exact series Prometheus scrapes (`PromEx.get_metrics/1` —
  the point: the user-facing number and the SLO dashboard quote one
  source) and computes each app's median total wake time by
  PromQL's histogram_quantile interpolation over the cumulative
  buckets of `flux_vale_wake_total_seconds`.

  Deliberate honesty guards:

  - `@min_samples`: an app shows a number only once N wakes are
    recorded — a single-sample median is one wake dressed up as a
    statistic ("never a raw single sample", #232).
  - Cached with a TTL (default 60s): the catalog re-renders far more
    often than wakes land, and the scrape walk is O(series); a
    minute-stale estimate is exactly as true as a fresh one. Test env
    pins the TTL to 0 so specs see their own emissions immediately.
  - PromEx down (dev/test default, or a booting tree) answers `%{}`
    — no badge, never a crash: the badge rides on the metrics
    pipeline, it isn't a dependency of the catalog.
  """

  use GenServer

  @min_samples 5
  # The total histogram's exposition prefix — keep in lockstep with
  # FluxVale.PromEx.Plugins.Wake.
  @total_bucket_prefix "flux_vale_wake_total_seconds_bucket{"
  @label_pattern ~r/(\w+)="([^"]*)"/
  @quantile 0.5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{computed_at: nil, medians: %{}}}
  end

  @impl GenServer
  def handle_call(:medians, _from, state) do
    if fresh?(state) do
      {:reply, state.medians, state}
    else
      medians = compute()

      {:reply, medians, %{computed_at: DateTime.utc_now(), medians: medians}}
    end
  end

  @doc """
  The median total wake seconds per app slug — `%{}` when the metrics
  tree is down or no app has enough samples yet.
  """
  @spec median_total_by_app() :: %{optional(String.t()) => float()}
  def median_total_by_app do
    GenServer.call(__MODULE__, :medians)
  end

  defp fresh?(%{computed_at: nil}), do: false

  defp fresh?(%{computed_at: computed_at}) do
    ttl = Application.get_env(:flux_vale, :wake_stats_ttl_seconds, 60)
    DateTime.diff(DateTime.utc_now(), computed_at, :second) < ttl
  end

  defp compute do
    case PromEx.get_metrics(FluxVale.PromEx) do
      metrics when is_binary(metrics) ->
        metrics
        |> bucket_counts()
        |> Map.new(fn {app, buckets} -> {app, median(buckets)} end)
        |> Enum.reject(fn {_app, estimate} -> is_nil(estimate) end)
        |> Map.new()

      :prom_ex_down ->
        %{}
    end
  end

  # app slug → cumulative bucket counts, off the scrape's bucket lines
  # only (the _count line is redundant with +Inf and skipped).
  defp bucket_counts(metrics) do
    metrics
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&bucket_line/1)
    |> Enum.group_by(fn {app, _bound, _count} -> app end, fn {_app, bound, count} ->
      {bound, count}
    end)
    |> Map.new(fn {app, bounds} -> {app, Map.new(bounds)} end)
  end

  # Anything that isn't exactly our bucket shape (label order varies,
  # other metrics' lines, malformed tails) falls to the catch-all —
  # a derived badge must never crash the catalog.
  defp bucket_line(@total_bucket_prefix <> _labels = line) do
    with [label_section, value] <- String.split(line, "} "),
         %{"app" => app, "le" => le} <- parse_labels(label_section),
         {count, ""} <- Float.parse(value),
         bound <- parse_bound(le) do
      [{app, bound, count}]
    else
      _not_ours -> []
    end
  end

  defp bucket_line(_other_line), do: []

  defp parse_labels(label_section) do
    pairs =
      label_section
      |> String.split("}", parts: 2)
      |> List.first()
      |> then(&Regex.scan(@label_pattern, &1, capture: :all_but_first))

    Map.new(pairs, fn [key, value] -> {key, value} end)
  end

  # The exporter writes whole bounds bare ("1", not "1.0") — Float.parse
  # takes both where String.to_float would not.
  defp parse_bound("+Inf"), do: :inf

  defp parse_bound(le) do
    {bound, _rest} = Float.parse(le)
    bound
  end

  # histogram_quantile's linear interpolation over cumulative buckets;
  # nil below @min_samples (the honesty guard).
  defp median(buckets) do
    total = Map.get(buckets, :inf, 0.0)

    if total >= @min_samples do
      quantile(buckets, @quantile * total)
    end
  end

  defp quantile(buckets, target) do
    bounds =
      buckets
      |> Map.delete(:inf)
      |> Enum.sort()

    if bounds == [] do
      nil
    else
      walk_buckets(bounds, 0.0, 0.0, target)
    end
  end

  # Every sample past the last bound: that bound is the honest floor
  # (all we know is "at least this").
  defp walk_buckets([], prev_bound, _prev_count, _target), do: prev_bound

  defp walk_buckets([{bound, count} | rest], prev_bound, prev_count, target) do
    if count >= target do
      # coveralls-ignore-start - unreachable while target > 0 (which
      # @min_samples guarantees: target = 0.5 × total ≥ 2.5): a
      # zero-increment bucket covering the target would need its
      # cumulative — the previous bucket's — to already be ≥ target,
      # and that earlier bucket would have covered first. Kept as the
      # division-by-zero guard for future parameter changes.
      in_bucket = count - prev_count

      if in_bucket == 0 do
        prev_bound
      else
        # coveralls-ignore-stop
        prev_bound + (bound - prev_bound) * (target - prev_count) / in_bucket
      end
    else
      walk_buckets(rest, bound, count, target)
    end
  end
end

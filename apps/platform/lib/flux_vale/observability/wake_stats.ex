defmodule FluxVale.Observability.WakeStats do
  @moduledoc """
  Per-app wake-time estimates derived from the live metric (#232) —
  the catalog badge's and the console wake widget's data source.

  Reads the exact series Prometheus scrapes (`PromEx.get_metrics/1` —
  the point: the user-facing number and the SLO dashboard quote one
  source) and computes two per-app estimates by PromQL's
  histogram_quantile interpolation over the cumulative buckets: the
  median total wake time (`flux_vale_wake_total_seconds` — the
  catalog badge) and the p95 promotion wait
  (`flux_vale_wake_promotion_wait_seconds` — the console widget,
  #702, the SLO's own series).

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
  # The histograms' exposition prefixes — keep in lockstep with
  # FluxVale.PromEx.Plugins.Wake (total feeds the medians,
  # promotion-wait the p95s).
  @total_bucket_prefix "flux_vale_wake_total_seconds_bucket{"
  @promotion_bucket_prefix "flux_vale_wake_promotion_wait_seconds_bucket{"
  @label_pattern ~r/(\w+)="([^"]*)"/
  @median_quantile 0.5
  @p95_quantile 0.95

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{computed_at: nil, medians: %{}, p95_promotions: %{}}}
  end

  @impl GenServer
  def handle_call(:medians, _from, state) do
    {reply, state} = refresh(state, :medians)
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call(:p95_promotions, _from, state) do
    {reply, state} = refresh(state, :p95_promotions)
    {:reply, reply, state}
  end

  # The TTL cache's one refill: both families come out of a single
  # compute() (one scrape walk), so a stale read of either key
  # refreshes the shared stamp and the other family rides along.
  defp refresh(state, key) do
    if fresh?(state) do
      {Map.fetch!(state, key), state}
    else
      computed = Map.put(compute(), :computed_at, DateTime.utc_now())
      {Map.fetch!(computed, key), computed}
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

  @doc """
  `median_total_by_app/0` behind the badges' safety wrapper: any crash
  or exit answers `%{}` — a derived badge must never take its page
  down. Shared by the catalog index and the public app page (#611 S2,
  extracted from the index's private twin).
  """
  @spec median_total_by_app_safe() :: %{optional(String.t()) => float()}
  def median_total_by_app_safe do
    median_total_by_app()
  rescue
    # coveralls-ignore-start - both arms answer {} so the badge can't
    # take the catalog down; the named server is alive under the app
    # tree for the whole suite (a call exits only in the supervisor's
    # restart gap, which no test can hold open).
    _exception ->
      %{}
  catch
    :exit, _reason ->
      %{}
      # coveralls-ignore-stop
  end

  @doc """
  The p95 promotion-wait seconds per app slug — the console wake
  widget's number (#702, the SLO's own series). `%{}` when the
  metrics tree is down or no app has enough samples yet.
  """
  @spec p95_promotion_by_app() :: %{optional(String.t()) => float()}
  def p95_promotion_by_app do
    GenServer.call(__MODULE__, :p95_promotions)
  end

  @doc """
  `p95_promotion_by_app/0` behind the same safety wrapper as the
  medians — a derived widget must never take its page down.
  """
  @spec p95_promotion_by_app_safe() :: %{optional(String.t()) => float()}
  def p95_promotion_by_app_safe do
    p95_promotion_by_app()
  rescue
    # coveralls-ignore-start - both arms answer {} so the widget can't
    # take the console down; the named server is alive under the app
    # tree for the whole suite (a call exits only in the supervisor's
    # restart gap, which no test can hold open).
    _exception ->
      %{}
  catch
    :exit, _reason ->
      %{}
      # coveralls-ignore-stop
  end

  defp fresh?(%{computed_at: nil}), do: false

  defp fresh?(%{computed_at: computed_at}) do
    ttl = Application.get_env(:flux_vale, :wake_stats_ttl_seconds, 60)
    DateTime.diff(DateTime.utc_now(), computed_at, :second) < ttl
  end

  defp compute do
    case PromEx.get_metrics(FluxVale.PromEx) do
      metrics when is_binary(metrics) ->
        totals = bucket_counts(metrics, @total_bucket_prefix)
        promotions = bucket_counts(metrics, @promotion_bucket_prefix)

        %{
          medians: estimates(totals, &median/1),
          p95_promotions: estimates(promotions, &p95/1)
        }

      :prom_ex_down ->
        %{medians: %{}, p95_promotions: %{}}
    end
  end

  # app slug → estimate, dropping the apps the honesty guard silences.
  defp estimates(buckets_by_app, estimator) do
    buckets_by_app
    |> Map.new(fn {app, buckets} -> {app, estimator.(buckets)} end)
    |> Enum.reject(fn {_app, estimate} -> is_nil(estimate) end)
    |> Map.new()
  end

  # app slug → cumulative bucket counts, off the scrape's bucket lines
  # only (the _count line is redundant with +Inf and skipped). The
  # prefix selects the family: total lines feed the medians,
  # promotion lines the p95s — a line parses for exactly one family.
  defp bucket_counts(metrics, prefix) do
    metrics
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&bucket_line(&1, prefix))
    |> Enum.group_by(fn {app, _bound, _count} -> app end, fn {_app, bound, count} ->
      {bound, count}
    end)
    |> Map.new(fn {app, bounds} -> {app, Map.new(bounds)} end)
  end

  # Anything that isn't exactly our bucket shape falls to the catch-all —
  # a derived badge must never crash the catalog. The else arm in the
  # parse is coveralls-ignored: a real scrape (the only input path)
  # either carries the family's prefix and parses, or lacks it and
  # skips; the else is reachable only on malformed text the exporter
  # can't produce.
  defp bucket_line(line, prefix) do
    if String.starts_with?(line, prefix) do
      parse_bucket_line(line)
    else
      []
    end
  end

  defp parse_bucket_line(line) do
    with [label_section, value] <- String.split(line, "} "),
         %{"app" => app, "le" => le} <- parse_labels(label_section),
         {count, ""} <- Float.parse(value),
         bound <- parse_bound(le) do
      [{app, bound, count}]
    else
      # coveralls-ignore-next-line - see bucket_line/2
      _not_ours -> []
    end
  end

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
  # nil below @min_samples (the honesty guard). Median and p95 are the
  # same walk at their quantiles.
  defp median(buckets), do: quantile_at(buckets, @median_quantile)

  defp p95(buckets), do: quantile_at(buckets, @p95_quantile)

  defp quantile_at(buckets, q) do
    total = Map.get(buckets, :inf, 0.0)

    if total >= @min_samples do
      quantile(buckets, q * total)
    end
  end

  defp quantile(buckets, target) do
    bounds =
      buckets
      |> Map.delete(:inf)
      |> Enum.sort()

    if bounds == [] do
      # coveralls-ignore-next-line - defensive: the exporter always
      # emits the full finite bucket set alongside +Inf, so an app
      # with samples but no finite bounds can't come out of a scrape.
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
      # @min_samples guarantees for both quantiles: target = q × total
      # ≥ 0.5 × 5 = 2.5): a zero-increment bucket covering the target
      # would need its cumulative — the previous bucket's — to already
      # be ≥ target, and that earlier bucket would have covered first.
      # Kept as the division-by-zero guard for future parameter changes.
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

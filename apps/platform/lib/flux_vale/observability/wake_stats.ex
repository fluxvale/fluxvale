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

  - Two sample floors, one per quantile: an app shows its median only
    once 5 wakes are recorded — a single-sample median is one wake
    dressed up as a statistic ("never a raw single sample", #232) —
    and its p95 only once 20 are. The floors differ because a tail
    quantile is greedier: at n=5 the 0.95 target rank lands in the
    bucket holding the single largest observation, so the "p95" would
    be one wake in costume.
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
  # The tail quantile's own honesty floor — see the moduledoc.
  @p95_min_samples 20
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
    state = refresh(state)
    {:reply, state.medians, state}
  end

  @impl GenServer
  def handle_call(:p95_promotions, _from, state) do
    state = refresh(state)
    {:reply, state.p95_promotions, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    state = refresh(state)
    {:reply, %{medians: state.medians, p95_promotions: state.p95_promotions}, state}
  end

  # The TTL cache's one refill: both families come out of a single
  # compute() (one fetch, one partition pass), so a stale read of
  # anything — a single key or the pair — refreshes the shared stamp
  # and answers from that one computation.
  defp refresh(state) do
    if fresh?(state) do
      state
    else
      Map.put(compute(), :computed_at, DateTime.utc_now())
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

  @doc """
  Both families in one read — the console widget's seam (#702). One
  `GenServer.call` answers the pair from one state read, so the two
  maps always quote the same computation (the TTL can't lapse between
  them the way two separate calls would).
  """
  @spec snapshot() :: %{
          medians: %{optional(String.t()) => float()},
          p95_promotions: %{optional(String.t()) => float()}
        }
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  The badges' wake-copy formatter: shared by the catalog and the
  console widget so the same series renders under one convention.
  """
  # The badge's copy: an honest ~estimate (median of N wakes, the same
  # series the SLO dashboard charts — WakeStats), rounded to the
  # second; over a minute, minutes-and-seconds reads truer than "74s".
  @spec format_estimate(number()) :: String.t()
  def format_estimate(seconds) do
    rounded = round(seconds)

    if rounded < 60 do
      "~#{rounded}s"
    else
      "~#{div(rounded, 60)}m #{rem(rounded, 60)}s"
    end
  end

  defp fresh?(%{computed_at: nil}), do: false

  defp fresh?(%{computed_at: computed_at}) do
    ttl = Application.get_env(:flux_vale, :wake_stats_ttl_seconds, 60)
    DateTime.diff(DateTime.utc_now(), computed_at, :second) < ttl
  end

  defp compute do
    case PromEx.get_metrics(FluxVale.PromEx) do
      metrics when is_binary(metrics) ->
        # ONE walk over the exposition: the split happens once and each
        # line is classified into its family in the same pass — both
        # families come out of a single fetch AND a single parse.
        {totals, promotions} =
          metrics
          |> String.split("\n", trim: true)
          |> Enum.reduce({%{}, %{}}, &partition_line/2)

        %{
          medians: estimates(totals, &median/1),
          p95_promotions: estimates(promotions, &p95/1)
        }

      :prom_ex_down ->
        %{medians: %{}, p95_promotions: %{}}
    end
  end

  # app slug → estimate, dropping the apps the honesty floors silence.
  defp estimates(buckets_by_app, estimator) do
    buckets_by_app
    |> Map.new(fn {app, buckets} -> {app, estimator.(buckets)} end)
    |> Enum.reject(fn {_app, estimate} -> is_nil(estimate) end)
    |> Map.new()
  end

  # Classify one exposition line into exactly one family's accumulator
  # (total lines feed the medians, promotion lines the p95s — a line
  # parses for at most one family); everything else (_sum/_count/HELP,
  # other plugins' series) falls through untouched.
  defp partition_line(line, {totals, promotions}) do
    cond do
      String.starts_with?(line, @total_bucket_prefix) ->
        {into_family(totals, line), promotions}

      String.starts_with?(line, @promotion_bucket_prefix) ->
        {totals, into_family(promotions, line)}

      true ->
        {totals, promotions}
    end
  end

  # Fold the line's {app, bound, cumulative count} into the family's
  # app → bounds map (the _count line is redundant with +Inf and never
  # carries a family prefix). Anything that isn't exactly our bucket
  # shape falls out unchanged in the else — a derived badge must never
  # crash the catalog; the arm is coveralls-ignored because a real
  # scrape (the only input path) that carries the prefix parses, and
  # the else is reachable only on malformed text the exporter can't
  # produce.
  defp into_family(acc, line) do
    with [label_section, value] <- String.split(line, "} "),
         %{"app" => app, "le" => le} <- parse_labels(label_section),
         {count, ""} <- Float.parse(value),
         bound <- parse_bound(le) do
      Map.update(acc, app, %{bound => count}, fn bounds -> Map.put(bounds, bound, count) end)
    else
      # coveralls-ignore-next-line - see above
      _not_ours -> acc
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
  # nil below the quantile's sample floor (the honesty guards — see the
  # moduledoc: 5 for the median, 20 for the tail quantile). Median and
  # p95 are the same walk at their quantiles.
  defp median(buckets), do: quantile_at(buckets, @median_quantile, @min_samples)

  defp p95(buckets), do: quantile_at(buckets, @p95_quantile, @p95_min_samples)

  defp quantile_at(buckets, q, min_samples) do
    total = Map.get(buckets, :inf, 0.0)

    if total >= min_samples do
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
      # coveralls-ignore-start - the guard protects the division below,
      # not the reader: an in_bucket of 0 would divide by zero. It is
      # unreachable today (a zero-increment bucket covering the target
      # would need its cumulative — the previous bucket's — to already
      # be ≥ target, and that earlier bucket would have covered first),
      # but it stays for future parameter changes, which is exactly
      # when it would silently matter.
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

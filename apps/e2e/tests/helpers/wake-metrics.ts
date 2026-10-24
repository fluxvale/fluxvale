import type { APIRequestContext } from "@playwright/test";

// #232's wake SLI, read from the platform's own /metrics exposition
// (PromEx — the e2e bootstrap enables it via PROMEX_ENABLED; the
// token gate stays unset on local/CI clusters). The wake test's
// cold-start ceiling derives from what the platform measured for the
// SAME wake — a snapshot before t0, the delta at assert time — so
// runner variance moves both numbers together instead of breaking a
// fixed constant (the retired 60s ceiling failed two consecutive
// nightlies at 60.0s while a green run measured 58s; the platform's
// `total` includes the minute-cadence reconciler by design, so real
// full-cadence wakes sit near the minute mark).
//
// The exposition line shape (`metric{app="…"}` — the label set is
// app-only and renders app-first) is the contract of
// FluxVale.PromEx.Plugins.Wake on the platform side; keep this
// parser in lockstep with it (the platform's own twin parser,
// WakeStats, carries the same note).
const TOTAL_SUM = "flux_vale_wake_total_seconds_sum";
const TOTAL_COUNT = "flux_vale_wake_total_seconds_count";

// #232's own pathological-headroom bucket — the fallback whenever the
// SLI can't be read (tree down, 503, or no new sample): an
// observability hiccup must not fail the fidelity gate on a local
// run. CI legs set E2E_REQUIRE_WAKE_SLI=1 to make degradation loud
// instead — the bootstrap guarantees the tree there.
const FALLBACK_CEILING_MS = 180_000;

// The platform's `total` clock stops at the :running write; the
// test's clock runs to first-served. The gap is request transit +
// debounced route restore + Traefik convergence + this loop's 1s
// poll — measured sub-second on the artifact runs, budgeted 10s
// here. The app-specific magnitude itself rides the SLI number,
// never this constant.
const OVERHEAD_SLOP_MS = 10_000;

type SliSnapshot = { sum: number; count: number };

/**
 * The wake-total histogram state for `app`, or null when /metrics is
 * unreadable. An absent series is the ZERO state, not an error —
 * Prometheus omits unobserved series from the exposition, so a fresh
 * run's first wake pairs against {0, 0} (CodeRabbit, verified on the
 * first timers leg: attempt 1 red on "unreadable before the wake",
 * the retry paired off attempt 1's own sample). Take one before the
 * wake starts and pass it to wakeCeilingMs — the delta over the wake
 * is this wake's own sample, by construction (immune to samples from
 * earlier wakes in the same cluster, including a local k3d reused
 * across runs).
 */
export async function wakeSliSnapshot(
  request: APIRequestContext,
  app: string,
): Promise<SliSnapshot | null> {
  const res = await request.get("/metrics").catch(() => null);
  if (!res || res.status() !== 200) return null;

  const exposition = await res.text();
  const sum = sampleValue(exposition, TOTAL_SUM, app);
  const count = sampleValue(exposition, TOTAL_COUNT, app);

  if (sum === null && count === null) return { sum: 0, count: 0 };
  // A half-present series (one line present, one missing) is
  // malformed exposition — no honest reading either way.
  if (sum === null || count === null) return null;

  return { sum, count };
}

/**
 * The consistency ceiling for a wake bracketed by `before`: the mean
 * of the samples the SLI recorded DURING the wake (delta of
 * sum/count), plus the overhead slop. With E2E_REQUIRE_WAKE_SLI=1 a
 * missing tree or a missing sample throws instead of degrading.
 */
export async function wakeCeilingMs(
  request: APIRequestContext,
  app: string,
  before: SliSnapshot | null,
): Promise<{ ceilingMs: number; meanTotalMs: number | null; samples: number }> {
  const after = await wakeSliSnapshot(request, app);
  const requireSli = process.env.E2E_REQUIRE_WAKE_SLI === "1";

  // Pairing needs both ends and a forward-moving counter: a snapshot
  // missing on either side (tree down at one read) or a counter reset
  // (platform pod restarted mid-run) leaves no honest delta.
  if (after === null || before === null || after.count < before.count || after.sum < before.sum) {
    const why =
      after === null
        ? "/metrics unreadable after the wake"
        : before === null
          ? "/metrics unreadable before the wake (an absent series is the zero state, not this)"
          : "histogram counters moved backwards (platform restart?)";

    degrade(requireSli, why);

    return { ceilingMs: FALLBACK_CEILING_MS, meanTotalMs: null, samples: 0 };
  }

  const deltaCount = after.count - before.count;

  if (deltaCount === 0) {
    degrade(
      requireSli,
      "no wake sample recorded during the wake (series missing or it never completed)",
    );

    return { ceilingMs: FALLBACK_CEILING_MS, meanTotalMs: null, samples: 0 };
  }

  // Delta-of-histograms, not the cumulative mean: only the samples
  // recorded during THIS wake enter the ceiling — typically exactly
  // one (the wake this test just timed).
  const deltaSum = after.sum - before.sum;
  const meanTotalMs = (deltaSum / deltaCount) * 1000;
  console.log(
    `wake SLI ${app}: mean total ${Math.round(meanTotalMs)}ms over ${deltaCount} sample(s) this wake`,
  );

  return { ceilingMs: meanTotalMs + OVERHEAD_SLOP_MS, meanTotalMs, samples: deltaCount };
}

// Loud where CI demands the instrument, lenient where a local run
// just wants the suite to pass without the observability tree.
function degrade(requireSli: boolean, why: string): void {
  if (requireSli) {
    throw new Error(`wake SLI required but unusable: ${why}`);
  }

  console.log(`wake SLI unusable (${why}) — fallback ceiling ${FALLBACK_CEILING_MS}ms`);
}

// One series line: `metric{app="forgejo"} 59.7` — single-label
// exposition, exact prefix match on the metric + label.
function sampleValue(
  exposition: string,
  metric: string,
  app: string,
): number | null {
  const line = exposition
    .split("\n")
    .find((l) => l.startsWith(`${metric}{app="${app}"}`));

  if (!line) return null;

  const value = Number(line.split(/\s+/).pop());
  return Number.isFinite(value) ? value : null;
}

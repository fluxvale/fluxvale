defmodule FluxVale.Analytics do
  @moduledoc """
  Server-side product events (ADR-0049, S1b of the PostHog split,
  #706): the one seam domain operations call to capture `[object]
  [verb]` events — the SDK's event-name convention ("instance deploy
  started", "wallet topped up", …).

  The structural kill switch applies here too: `(:flux_vale, :posthog)`
  is nil unless `POSTHOG_API_KEY` arms it (runtime.exs), and nil means
  `capture/3` is a no-op `:ok` that never touches the SDK — this slice
  ships inert everywhere until the fleet flips the var.

  Armed, the call is fire-and-forget. `PostHog.capture/2` prepares the
  event synchronously and hands it to the SDK's sender workers, which
  batch and ship over the wire on their own time (the HTTP call runs in
  the sender GenServer, never in the caller) — so `capture/2` never
  blocks on the network and the facade returns `:ok` unconditionally. A
  dropped event is the SDK's contract, never the caller's problem.

  `distinct_id` is the ACTING user's id (or the owning org's, where the
  flow has no user), passed explicitly — process context does not
  transfer across processes. The argument always wins: caller props
  cannot set or override it, and the nil arm (reserved for genuinely
  anonymous future uses) strips any props-carried id so the SDK drops
  the event rather than attributing it. Props stay minimal — ids and
  slugs only; no emails, tokens, payment references, or billing
  amounts ride them (the PostHogRequestContext posture; money questions
  live in the Grafana domain dashboards, ADR-0012's domain sight).
  """

  @doc """
  Captures a product event for `distinct_id`, fire-and-forget. Returns
  `:ok` in every arm.
  """
  @spec capture(String.t(), String.t() | nil, map()) :: :ok
  def capture(event, distinct_id, props \\ %{}) do
    case Application.get_env(:flux_vale, :posthog) do
      nil ->
        # The kill switch (ADR-0049): unarmed means the SDK is never
        # called — no tree is running to receive an event.
        :ok

      _armed ->
        merged = merged_props(props, distinct_id)

        PostHog.capture(event, merged)

        :ok
    end
  end

  # The id always comes from the argument, merged in LAST so a caller's
  # props map can never set or override it (and neither can whatever
  # request context the SDK holds for this process — the SDK merges
  # context under the props we hand it). The nil arm strips any
  # props-carried id: anonymous means anonymous, the SDK then drops the
  # event (its contract for a missing distinct id).
  defp merged_props(props, nil), do: Map.delete(props, :distinct_id)

  defp merged_props(props, distinct_id), do: Map.put(props, :distinct_id, distinct_id)
end

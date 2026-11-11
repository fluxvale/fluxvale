defmodule FluxVale.Analytics do
  @moduledoc """
  Server-side product events (ADR-0049, S1b of the PostHog split,
  #706): the one seam domain operations call to capture `[object]
  [verb]` events — the SDK's event-name convention ("instance
  deployed", "wallet topped up", …).

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

  `distinct_id` is the ACTING user's id, passed explicitly — process
  context does not transfer across processes, and a background worker
  or the actorless edge has none (nil is anonymous; the SDK then drops
  the event, its contract for a missing distinct id). Props stay
  minimal — ids and slugs only; no emails, tokens, or payment
  references ride them (the PostHogRequestContext posture).
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

  # The id always comes from the argument — a caller's props map can
  # never override it, and neither can whatever request context the SDK
  # holds for this process. nil (anonymous) omits the key entirely.
  defp merged_props(props, nil), do: props
  defp merged_props(props, distinct_id), do: Map.put(props, :distinct_id, distinct_id)
end

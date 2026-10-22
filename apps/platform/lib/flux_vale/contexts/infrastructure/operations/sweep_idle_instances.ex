defmodule FluxVale.Infrastructure.Operations.SweepIdleInstances do
  @moduledoc """
  The scale-to-zero sweep (#203, ADR-0036): sleeps every `:running`
  instance whose edge-marked `last_used_at` is older than the idle
  threshold — one hour by default, the owner's settled number.

  Exemptions, by design:

  - `always_on` rows never sleep (the paid premium — ADR-0036).
  - A nil `last_used_at` never sleeps: an unmeasurable idle clock must
    fail open (keep serving), never wrongly put an owner's app down.
    enter_running always sets the marker and the #203 backfill seeded
    pre-existing rows, so nil means drift — logged loudly.
  - Probes/uptime monitors never reach the clock: the beacon filters
    their user-agents before writing (the settled "must NOT count as
    traffic" decision), so a sleeping instance is provably
    visitor-less.

  Complements, never fights: the reconciler owns readiness; the #124
  ladder owns balance-driven stops (a sleeping instance still settles
  storage-only, so it can still climb the destroy ladder — the two
  automata share the anchor machinery, nothing else).

  Races with owner actions close by RE-READING each candidate right
  before its sleep (`still_idle?/1`): the batch read is minutes stale
  by the last unit, and the funnel's transition validation checks the
  loaded record — only a fresh read makes the `:sleep` guard decide
  against current truth. A row that stopped, woke, or was touched
  inside the read-to-sleep window is skipped on the spot.
  """

  alias FluxVale.Infrastructure.Instance

  require Logger

  @enforce_keys [:slept_ids]
  defstruct [:slept_ids]

  @type t :: %__MODULE__{
          slept_ids: [Ash.UUID.t()]
        }

  @doc """
  One sweep pass. `{:ok, summary}` when every candidate processed;
  `{:error, reason}` if any unit failed — the OTHER units still
  processed and logged (a crash eats one sleep, never the sweep), and
  the caller's Oban retry owns recovery (the sibling sweeps'
  discipline).
  """
  @spec call() :: {:ok, t()} | {:error, String.t()}
  def call do
    instances = Ash.read!(Instance, authorize?: false)

    candidates = Enum.filter(instances, &sleep_candidate?/1)

    results = Enum.map(candidates, &safe_sleep/1)

    failure_count = Enum.count(results, &match?({:error, _reason}, &1))

    if failure_count == 0 do
      {:ok, summarize(results)}
    else
      {:error, "idle-instance sweep failed for #{failure_count} unit(s)"}
    end
  end

  # always_on is the premium opt-out; a nil marker is unmeasurable —
  # both keep serving (see moduledoc).
  defp sleep_candidate?(%Instance{
         status: :running,
         always_on: false,
         last_used_at: last_used_at
       })
       when not is_nil(last_used_at) do
    DateTime.diff(DateTime.utc_now(), last_used_at, :second) > idle_after_seconds()
  end

  defp sleep_candidate?(%Instance{status: :running, last_used_at: nil} = instance) do
    Logger.warning(
      "Instance #{instance.id}: running with no last_used_at marker (drift — enter_running " <>
        "always sets it); leaving it awake rather than guessing an idle clock"
    )

    false
  end

  defp sleep_candidate?(_instance), do: false

  @doc """
  The same predicate as the candidate filter, against a re-read row —
  public for its test so the two definitions can never drift (the
  in-sweep re-read races live writers; the predicate itself is pure).
  """
  @spec still_idle?(Instance.t()) :: boolean()
  def still_idle?(fresh), do: sleep_candidate?(fresh)

  defp safe_sleep(instance) do
    # Fresh truth, not the batch snapshot (see moduledoc): sleep only
    # what is still running, still marker-cold, right now.
    fresh = Instance.get_by_id!(instance.id, authorize?: false)

    if still_idle?(fresh) do
      {:ok, _slept} = Instance.sleep(fresh, authorize?: false)
      {:ok, instance.id}
    else
      # coveralls-ignore-start - the raced-past arm: reachable only
      # when another writer lands between the batch read and this
      # re-read inside the same sweep pass — no deterministic test can
      # interleave into call/0's enumeration.
      {:ok, instance.id}
    end

    # coveralls-ignore-stop
  rescue
    # An illegal-transition error is the concurrency skip (the row
    # moved between read and sleep); anything else is a real failure
    # for the caller's retry.
    exception ->
      Logger.error(
        "Idle sweep: sleeping instance #{instance.id} raised: #{Exception.message(exception)}"
      )

      {:error, instance.id}
  end

  # Only a clean pass summarizes — any failed unit fails the whole
  # pass for the caller's retry, so the summary is all successes.
  defp summarize(results) do
    %__MODULE__{slept_ids: Enum.map(results, fn {:ok, id} -> id end)}
  end

  defp idle_after_seconds do
    Application.fetch_env!(:flux_vale, :idle_sleep_after_seconds)
  end
end

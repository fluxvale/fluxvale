defmodule FluxVale.Identity.Operations.PruneDeviceCodes do
  @moduledoc """
  Sweeps device-flow rows dead for longer than the retention horizon
  (v1's janitor posture — PruneRequestWindows' shape, #362 T3).

  A row dead for a day can never answer a poll again (the 10-minute
  TTL is long gone; :consumed/:denied are terminal), so the horizon
  only bounds storage, not correctness.
  """

  alias FluxVale.Identity.DeviceCode

  # One day (PruneRequestWindows' tie): a consumed/denied row keeps
  # answering the wire for a day after its death, then goes.
  @retention_seconds 24 * 60 * 60

  @doc """
  Deletes all device codes whose row has been dead longer than the
  retention horizon (past `expires_at`, or terminal :consumed/:denied
  longer than a day — see the :stale read).

  Returns `{:ok, count}`. Callers are system processes (the janitor)
  — `authorize?: false` explicitly, the PruneExpiredTokens posture.
  """
  @spec call(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_seconds, :second)

    # Count first, destroy without records: `return_records?` would
    # hold every dead row in memory for the sweep, and this table's
    # feed is unbounded (the mint endpoint is unauthenticated; IP
    # limiting is the named follow-up). The count is a read that
    # precedes the destroy — a row the sweep creates/finishes in that
    # gap lands in the next day's sweep, and the janitor only logs the
    # number.
    {:ok, count} =
      DeviceCode
      |> Ash.Query.for_read(:stale, %{cutoff: cutoff})
      |> Ash.count(authorize?: false)

    result =
      DeviceCode
      |> Ash.Query.for_read(:stale, %{cutoff: cutoff})
      |> Ash.bulk_destroy(:expunge_stale, %{}, opts)

    case result do
      %Ash.BulkResult{status: :success} ->
        {:ok, count}

      # coveralls-ignore-start - bulk failure = DB outage mid-destroy; the
      # Oban retry policy owns recovery (AGENTS: cluster-level concern)
      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
        # coveralls-ignore-stop
    end
  end
end

defmodule FluxVale.Api.Operations.PruneRequestWindows do
  @moduledoc """
  Sweeps request windows older than the retention horizon (v1's
  janitor posture, mirrored on the metering rows — #360 slice 3).

  A window older than a day can never receive another count (the
  plug only ever writes the current window), so the horizon only
  bounds storage, not correctness.
  """

  alias FluxVale.Api.RequestWindow

  # One day: generous against clock skew, still swept daily (a
  # runaway token produces at most ~32k rows/day at the default cap).
  @retention_seconds 24 * 60 * 60

  @doc """
  Deletes all request windows whose `window_started_at` is older than
  the retention horizon.

  Returns `{:ok, count}` where `count` is the number of deleted rows.
  Callers are system processes (the janitor) — `authorize?: false`
  explicitly, the PruneExpiredTokens posture.
  """
  @spec call(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_seconds, :second)
    opts = Keyword.put(opts, :return_records?, true)

    result =
      RequestWindow
      |> Ash.Query.for_read(:stale, %{cutoff: cutoff})
      |> Ash.bulk_destroy(:expunge_stale, %{}, opts)

    case result do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, length(records)}

      # coveralls-ignore-start - bulk failure = DB outage mid-destroy; the
      # Oban retry policy owns recovery (AGENTS: cluster-level concern)
      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
        # coveralls-ignore-stop
    end
  end
end

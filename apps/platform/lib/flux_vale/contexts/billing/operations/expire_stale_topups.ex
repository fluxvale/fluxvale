defmodule FluxVale.Billing.Operations.ExpireStaleTopups do
  @moduledoc """
  Expires stale pending top-ups — the local staleness policy (#364): a
  row still `:pending` after `@ttl_hours` is abandoned (the buyer never
  paid, or the gateway never answered) and flips to `:expired`, so the
  confirmation view can say so.

  Not a failure verdict: a gateway `expired` answer is a failure report
  (ReconcileTopup → FailTopup) — that path is untouched. Money that
  lands after local expiry still completes and credits:
  CompleteTopup's bulk guard accepts `:expired` rows (webhook retries
  can lag past the TTL).

  Terminal-once via the status filter riding the UPDATE's WHERE (the
  FailTopup guard shape): a row completed mid-sweep loses, never
  flips. System operation, `authorize?: false`.
  """

  alias FluxVale.Billing.Topup

  require Ash.Query

  # Pending past this window is abandoned, not awaited. Revisit
  # trigger: gateway webhook retry lag — a completion landing after
  # local expiry still credits via CompleteTopup's widened guard, so
  # a wrong value here only shifts display, never money.
  @ttl_hours 24

  @spec call() :: {:ok, [Topup.t()]} | {:error, term()}
  def call do
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_hours * 3600, :second)

    # Terminal-once: the status filter rides the UPDATE's WHERE, so a
    # completed row never turns expired — the guard, not an Elixir
    # pre-check, decides (the out-of-order-delivery answer).
    query =
      Ash.Query.filter(Topup, status == :pending and created_at < ^cutoff)

    result =
      Ash.bulk_update(query, :mark_expired, %{},
        authorize?: false,
        return_records?: true,
        notify?: false
      )

    case result do
      %Ash.BulkResult{status: :success, records: expired} ->
        {:ok, expired}

      # DB-level failure — not simulatable under the sandbox (the same
      # class as FailTopup's arm); the hourly retry re-runs this.
      # coveralls-ignore-next-line
      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end
end

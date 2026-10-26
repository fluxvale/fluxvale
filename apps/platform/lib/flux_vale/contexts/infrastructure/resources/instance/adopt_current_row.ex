defmodule FluxVale.Infrastructure.Instance.AdoptCurrentRow do
  @moduledoc """
  The :deploy trigger's staleness answer (PR #267 review round 2,
  finding P2-1): converge, never cancel.

  A `before_action` hook — running INSIDE the action's own
  transaction — re-reads the row `FOR UPDATE` and swaps it into the
  changeset (AshOban's own generated workers use the same
  `%{changeset | data: record}` move for their `lock_for_update?`
  path). Two effects:

  - **Converge on truth**: the deploy runs against the row's CURRENT
    committed record — exposure included — so a racing exposure
    toggle that committed after this job loaded the row is adopted,
    not fought. The alternative (an optimistic lock) fails the write
    with StaleRecord, which AshOban maps to a CANCELLED job — a
    cancelled deploy strands the row in `:deploying` until the
    reconciler's stale-deploy timeout or an owner's manual retry, and
    the racing toggle never owned workload convergence anyway
    (`set_exposure` applies only the edge posture; only the deploy
    materializes the workload).
  - **Serialize the cluster windows**: the FOR UPDATE lock is held
    from the re-read to the action's commit, and the deploy's K8s
    applies run inside that window — a concurrent `set_exposure`
    (whose own UPDATE holds the same row lock across its synchronous
    cluster apply) blocks until the deploy commits, then applies its
    posture to a settled world. Whichever wins, the loser runs
    against the winner's committed truth; the K8s windows never
    interleave.

  A row that vanished (teardown won the race) raises AshOban's own
  `TriggerNoLongerApplies` — the one cancel that is correct: there is
  nothing left to deploy.
  """

  use Ash.Resource.Change

  alias AshOban.Errors.TriggerNoLongerApplies
  alias FluxVale.Infrastructure.Instance

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      adopt(changeset)
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (a locked read and a K8s deploy live in the hooks)
  def atomic?, do: false

  defp adopt(changeset) do
    query =
      Instance
      |> Ash.Query.filter(id == ^changeset.data.id)
      |> Ash.Query.lock(:for_update)

    case Ash.read_one(query, authorize?: false) do
      {:ok, nil} ->
        # Teardown hard-deleted the row: the trigger's work is gone
        # with it — the sanctioned cancel, exactly AshOban's own
        # re-read stance for a vanished primary key.
        Ash.Changeset.add_error(changeset, TriggerNoLongerApplies.exception([]))

      {:ok, record} ->
        %{changeset | data: record}

      # coveralls-ignore-start - defensive: a DB read failure here
      # (outage, dropped connection) is the one ExUnit can't stage —
      # DBConnection reconnects by design. The error fails the job for
      # Oban's retry, which is the correct owner of a transient read.
      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
        # coveralls-ignore-stop
    end
  end
end

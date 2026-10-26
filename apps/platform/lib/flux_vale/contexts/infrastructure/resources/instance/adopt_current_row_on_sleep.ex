defmodule FluxVale.Infrastructure.Instance.AdoptCurrentRowOnSleep do
  @moduledoc """
  The idle sweep's staleness answer (ADR-0039 §7, closing ADR-0038 §6's
  deferred window): the sleep must decide against the row's **current**
  exposure, never the record its caller loaded.

  The window it closes: `SweepIdleInstances` reads a batch, then calls
  `Instance.sleep/1` on each candidate. `:sleep` accepts no attributes,
  so before this change nothing wrote the row before
  `EdgeRoutes.apply_wake/2` ran — an owner's toggle to `:private` that
  committed inside the read-to-sleep gap was invisible, and the sleep
  minted a wake-mode **public** route onto a row the owner had just made
  private. `set_exposure`'s optimistic lock contends only with other
  toggles, so it never refused the sleep; `RestoreServingEdge` no-ops on
  private, so nothing at rest removed the route.

  The fix is the deploy's own shape (`AdoptCurrentRow`): a
  `before_action` re-read `FOR UPDATE` inside the action's transaction,
  swapping the fresh record into the changeset. Verified, not assumed —
  an Ash update's `before_action` runs inside the action's transaction
  for both attribute-accepting and `accept([])` actions, and the row
  adopted there is the record `after_action` receives (where the
  operations' K8s work runs). Two consequences:

  - the sleep sees the committed exposure (private → deletes, mints
    nothing);
  - the toggle blocks on the row lock until the sleep commits, then
    applies its posture to a settled world.

  Either order converges; no wake route survives a private row.

  A vanished row (teardown won) cancels the trigger — the one correct
  cancel, AshOban's own re-read stance.
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
  # coveralls-ignore-next-line trivial callback — always false (a locked read lives in the hook)
  def atomic?, do: false

  defp adopt(changeset) do
    query =
      Instance
      |> Ash.Query.filter(id == ^changeset.data.id)
      |> Ash.Query.lock(:for_update)

    case Ash.read_one(query, authorize?: false) do
      {:ok, nil} ->
        Ash.Changeset.add_error(changeset, TriggerNoLongerApplies.exception([]))

      {:ok, record} ->
        %{changeset | data: record}

      # coveralls-ignore-start - defensive: a DB read failure here
      # (outage, dropped connection) is the one shape ExUnit can't stage —
      # DBConnection reconnects by design. Failing the job is the correct
      # owner of a transient read (the AdoptCurrentRow stance).
      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
        # coveralls-ignore-stop
    end
  end
end

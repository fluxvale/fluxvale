defmodule FluxVale.Infrastructure.Instance.MaintainAnchors do
  @moduledoc """
  Maintains the Instance's metering anchors on status transitions
  (ADR-0005 Am. 1, ADR-0028 §2):

  - Entering `:running`: `running_since` = now (start of a billable
    running interval); `storage_metering_since` = now **only if nil** —
    seeded the first time the instance runs, then left alone so storage
    billing spans stop/start (the PVC persists and keeps accruing; a PVC
    on an instance that never went ready accrues unbilled until M5
    decides the edge — v1 semantics, kept).
  - Leaving `:running` (→ stopped | error | deleting): clear
    `running_since`; the storage anchor stays — M5's `settle_usage`
    (deferred from #73) advances it against the Wallet/ledger then.

  The `settle_usage` trigger itself is M5 scope: the ledger it posts to
  doesn't exist yet. Anchors ship now so M5 reads real history instead of
  backfilling.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    old_status = changeset.data.status
    new_status = Changeset.get_attribute(changeset, :status)

    cond do
      # coveralls-ignore-start - defensive: unreachable; status is
      # allow_nil? false, so new_status is never nil in practice.
      is_nil(new_status) ->
        changeset

      # coveralls-ignore-stop

      new_status == :running and old_status != :running ->
        enter_running(changeset)

      old_status == :running and new_status != :running ->
        leave_running(changeset)

      true ->
        changeset
    end
  end

  # Start a fresh running interval; seed the storage anchor on the
  # instance's first-ever deploy.
  defp enter_running(changeset) do
    now = DateTime.utc_now()
    changeset = Changeset.change_attribute(changeset, :running_since, now)

    if is_nil(changeset.data.storage_metering_since),
      do: Changeset.change_attribute(changeset, :storage_metering_since, now),
      else: changeset
  end

  # Running billing stops; storage accrual continues on the persisted
  # anchor (advanced by M5's settlement, not here).
  defp leave_running(changeset) do
    Changeset.change_attribute(changeset, :running_since, nil)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (attribute logic on old data)
  def atomic?, do: false
end

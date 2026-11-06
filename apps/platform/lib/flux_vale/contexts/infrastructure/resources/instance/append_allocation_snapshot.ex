defmodule FluxVale.Infrastructure.Instance.AppendAllocationSnapshot do
  @moduledoc """
  The resize's audit append (#493): closes the open era
  (`superseded_at` = now) and appends the new one (`effective_from` =
  now, carrying the UPDATED row's allocation + pricing) — both writes
  ride the resize action's transaction with the row update, so trail
  and row can never disagree. Rows are never edited, only superseded.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.InstanceAllocationSnapshot

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, updated ->
      now = DateTime.utc_now()
      supersede_open_era!(updated.id, now)
      record_new_era!(updated, now)

      {:ok, updated}
    end)
  end

  # authorize?: false on both writes — the trail is a system audit write
  # riding the resize's transaction (the resize policy already gated the
  # caller). A missing open era (data drift; the backfill mints era 1
  # for every row) still appends: the new era is the truth going
  # forward.
  defp supersede_open_era!(instance_id, now) do
    instance_id
    |> InstanceAllocationSnapshot.in_force!(authorize?: false)
    |> Enum.each(fn era ->
      InstanceAllocationSnapshot.supersede!(era, %{superseded_at: now}, authorize?: false)
    end)
  end

  defp record_new_era!(updated, now) do
    InstanceAllocationSnapshot.record!(
      %{
        instance_id: updated.id,
        cpu_cores: updated.cpu_cores,
        memory_mb: updated.memory_mb,
        storage_gb: updated.storage_gb,
        size_id: updated.size_id,
        monthly_cents: updated.grandfathered_monthly_cents,
        stopped_monthly_cents: updated.grandfathered_stopped_monthly_cents,
        effective_from: now
      },
      authorize?: false
    )
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (hooks)
  def atomic?, do: false
end

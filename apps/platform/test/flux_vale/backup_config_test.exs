defmodule FluxVale.BackupConfigTest do
  @moduledoc """
  #222 (ADR-0037 §3/§5): the backup/restore timeout chain is an invariant,
  not a comment. The watch pass's stale horizon must sit **above** the
  longest Job deadline, or it would fail a run that the Job's own
  `activeDeadlineSeconds` was still going to conclude — and the restore's
  deadline must sit above the backup's, because it moves every chunk in
  both directions.
  """

  use ExUnit.Case, async: true

  setup do
    {:ok, backups: Application.fetch_env!(:flux_vale, :backups)}
  end

  test "the horizon chain: stale_after > restore_timeout > timeout", %{backups: backups} do
    assert backups[:timeout_seconds] > 0
    assert backups[:restore_timeout_seconds] > backups[:timeout_seconds]
    assert backups[:stale_after_seconds] > backups[:restore_timeout_seconds]
  end

  # The scale-down wait (and the leftover-Job wait) are operational
  # bounds, not deadlines: they must outlast a normal rollout and stay
  # well inside the stale horizon, so a hung wait still leaves the row
  # recoverable.
  test "the waits are positive and inside the horizon", %{backups: backups} do
    assert backups[:scale_down_timeout_seconds] > 0
    assert backups[:job_delete_timeout_seconds] > 0

    assert backups[:scale_down_timeout_seconds] < backups[:stale_after_seconds]
    assert backups[:job_delete_timeout_seconds] < backups[:stale_after_seconds]
  end
end

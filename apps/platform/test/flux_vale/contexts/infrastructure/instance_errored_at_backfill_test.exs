defmodule FluxVale.Infrastructure.Instance.ErroredAtBackfillTest do
  @moduledoc """
  Pins the #182 errored_at backfill — the paper-trail derivation's last
  home (`ErroredAtBackfill.run/0` is the migration's own SQL), through
  the hostile-review probe's four shapes: single episode, re-entry, no
  trail, exited row.

  The rows are built in the PRE-backfill shape: the funnel walks stamp
  `errored_at` themselves (post-migration code), so the stampless-error
  state the migration met is produced by clearing the stamp through a
  same-status `pin!` write — StatusMarkers ignores same-status writes,
  so the forced nil lands untouched (a state real flows can no longer
  produce; the fixtures' own forced-change shape).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.ErroredAtBackfill
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Repo
  alias FluxVale.TestSupport.InstanceFixtures

  describe "run/0 (the migration's SQL path)" do
    test "a single stuck episode takes the trail's to-error instant" do
      errored = errored_instance!()

      :ok = ErroredAtBackfill.run()

      # Bind-then-call: the derivation picks the trail's LATEST to-error
      # instant (the episode's entry).
      instants = trail_instants(errored.id)
      expected = List.last(instants)
      assert stamp(errored) == expected

      # Idempotent: the trail is append-only history, so a re-run
      # re-derives the same instant.
      :ok = ErroredAtBackfill.run()

      assert stamp(errored) == expected
    end

    test "a re-entered episode takes the LATEST to-error instant, not the first" do
      # The probe's re-entry shape: error, recovered, error again. The
      # trail carries both to-error versions; the backfill must pick
      # the current episode's entry.
      created = instance!()
      starting = InstanceFixtures.walk_to!(created, :starting)
      {:ok, ep1} = InstanceK8s.update_status(starting, :error, "rollout failed")
      {:ok, running} = InstanceK8s.update_status(ep1, :running, nil)
      {:ok, ep2} = InstanceK8s.update_status(running, :error, "round two")

      # Pre-backfill shape (see the moduledoc).
      InstanceFixtures.pin!(ep2, errored_at: nil)

      [first_instant, second_instant] = trail_instants(created.id)

      :ok = ErroredAtBackfill.run()

      assert stamp(ep2) == second_instant
      refute stamp(ep2) == first_instant
    end

    test "a row the trail cannot date stays NULL" do
      # The Oct-23 zombie shape: the trail predates the row's episode,
      # so it carries no to-error version. NULL fails the gauge's
      # window comparison — an unknown entry time must not page.
      errored = errored_instance!()

      Repo.query!("DELETE FROM instances_versions WHERE version_source_id = $1", [
        Ecto.UUID.dump!(errored.id)
      ])

      :ok = ErroredAtBackfill.run()

      assert stamp(errored) == nil
    end

    test "a row no longer in :error is never touched" do
      # The exit cleared the stamp (post-migration code); the backfill's
      # status guard must keep it cleared — an exited episode is not
      # stuck regardless of what the trail says.
      errored = errored_instance!()
      {:ok, running} = InstanceK8s.update_status(errored, :running, nil)

      :ok = ErroredAtBackfill.run()

      assert stamp(running) == nil
    end
  end

  # The pre-backfill shape: the funnel stamps on entry (post-migration
  # code), so the stamp is cleared through a same-status write —
  # StatusMarkers ignores same-status writes and leaves the forced nil
  # alone.
  defp errored_instance! do
    created = instance!()
    starting = InstanceFixtures.walk_to!(created, :starting)

    {:ok, errored} =
      InstanceK8s.update_status(starting, :error, "rollout failed", :rollout_failed)

    InstanceFixtures.pin!(errored, errored_at: nil)
  end

  defp instance! do
    user =
      User.create!("backfill-#{System.unique_integer()}@fluxvale.test", %{}, authorize?: false)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    Instance.create!(
      %{name: "Backfill #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
      actor: user
    )
  end

  # The row's current stamp, re-read post-run (the backfill writes
  # behind the loaded struct).
  defp stamp(instance) do
    Repo.reload!(instance).errored_at
  end

  # Every to-error instant the trail carries for the instance, oldest
  # first — the same query shape the backfill's DISTINCT ON ranks.
  defp trail_instants(instance_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT version_inserted_at FROM instances_versions
        WHERE version_source_id = $1 AND changes ->> 'status' = 'error'
        ORDER BY version_inserted_at, id
        """,
        [Ecto.UUID.dump!(instance_id)]
      )

    Enum.map(rows, fn [ts] -> DateTime.from_naive!(ts, "Etc/UTC") end)
  end
end

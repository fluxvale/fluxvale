defmodule FluxVale.Infrastructure.BackupSetting.ApplyClusterState do
  @moduledoc """
  Panel parity for the BackupSetting JSON:API routes (#482): every
  routed save converges the cluster with the row through
  `FluxVale.Infrastructure.apply_backup_cluster_state/4` — the ONE
  cluster-side-effects entrypoint, shared with the panel's
  `ConfigureBackups` save. The `backup-config` Secret is re-applied
  (a blank/absent `:secret_access_key` keeps the stored password and
  key while RESTIC_REPOSITORY recomputes from the changeset's
  coordinates) and the backup margin quota re-applies. THE exception,
  mirroring the panel: a pause (an update flipping `enabled` true→false)
  touches nothing — it changes one attribute and no cluster state,
  because an UNPAID org must always be able to stop paying for backups.

  ONE deliberate difference from the panel's save, route-side: a first
  save (no stored Secret) carrying no secret applies the quota only
  instead of failing with `:secret_access_key_required` — the routes
  keep their pre-existing permissive create-without-secret shape; the
  panel's strict fresh rule stays the panel's. A save for an instance
  with no namespace fails `:not_deployed` exactly like the panel's.

  The apply rides `after_action` — only reached when the policies have
  authorized the write — and a failure fails the action: on create the
  insert rolls back (no row); on update the row rolls back to its OLD
  values. Neither path can leave a row claiming cluster state that
  never landed.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # A pause must never touch K8s — the unpaid escape depends on it.
    if pause?(changeset) do
      changeset
    else
      Ash.Changeset.after_action(changeset, &apply_cluster_state/2)
    end
  end

  # The update policy's unpaid escape (`changing_attributes(enabled:
  # [from: true, to: false])`) constrains only the transition itself —
  # Ash's ChangingAttributes check ignores whatever ELSE rides the
  # changeset — so any enabled true→false flip is a legal unpaid save
  # and skips the apply. That self-heals: an unpaid org's only legal
  # save IS the pause (every non-pause save is paid-gated), and a paid
  # org's coords-riding pause is re-converged by its next save or
  # re-enable via the always-apply.
  defp pause?(changeset) do
    changeset.action_type == :update and
      changeset.data.enabled == true and
      Ash.Changeset.get_attribute(changeset, :enabled) == false
  end

  # authorize?: false is a precondition read, not a bypass: the row's
  # own policies already fenced this caller to this instance (the
  # routes' save actions authorize via `relates_to_actor_via([:instance,
  # ...])`). The read only fetches the namespace the Secret lands in.
  defp apply_cluster_state(changeset, setting) do
    instance = Instance.get_by_id!(setting.instance_id, authorize?: false)
    secret = Ash.Changeset.get_argument(changeset, :secret_access_key)

    case Infrastructure.apply_backup_cluster_state(
           instance,
           changeset,
           %{secret_access_key: secret},
           fresh_secret: :optional
         ) do
      :ok ->
        {:ok, setting}

      {:error, _reason} = error ->
        error
    end
  end
end

defmodule FluxVale.Infrastructure.Instance.UpdateEnv do
  @moduledoc """
  The in-place env update (#731 T1, ADR-0052): one merge verb for an
  instance's user env, applied to the row and — when the row is
  deployed — the live `app-env` Secret, with a post-commit rolling
  restart for the live statuses.

  The three hooks, all registered up front (the `AccessDomain.Resume`
  precedent: hooks added inside a `before_action` are not on the
  changeset the engine hands to `after_transaction`):

  - `before_action` re-reads the row `FOR UPDATE`, runs the status
    guard, validates/merges the patch (`EnvPatch` + the create-time
    `ValidateEnvVars.check/2` on the merged map), force-changes
    `env_vars`, and stashes the apply plan in the process dictionary;
  - `after_action` upserts the live Secret inside the row transaction
    — a failure returns an `InvalidArgument` and rolls the row back
    (the Secret apply is atomic, so both stay old);
  - `after_transaction` deletes the stash, logs ONE key-name-only
    info line, and — for `running`/`starting` only — restarts the
    Deployment. A refused restart is a post-commit error ("the
    environment was saved, but the rolling restart was refused —
    retry"): the row and Secret stay applied, the pods lag, and the
    next retry/redeploy converges.

  Status rules (ADR-0052 decision 5): `pending`/`error`/`lost` row
  only; `running`/`starting` row + Secret + restart;
  `stopped`/`sleeping` row + Secret, no restart;
  `deploying`/`restoring`/`deleting` refuse. A patch with an empty
  final set/remove writes nothing and rolls nothing (the row is
  already what the caller asked for).
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.ValidateEnvVars
  alias FluxVale.Infrastructure.Operations.EnvPatch
  alias FluxVale.Infrastructure.Operations.InstanceEnvDerived
  alias FluxVale.Infrastructure.Operations.InstanceEnvSecret
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.PocketIdWiring

  require Ash.Query
  require Logger

  @stash_key :flux_vale_instance_update_env_plan

  @row_only [:pending, :error, :lost]
  @live [:running, :starting]
  @secret_only [:stopped, :sleeping]
  @updatable @row_only ++ @live ++ @secret_only
  @deployed @live ++ @secret_only
  @busy [:deploying, :restoring]

  @restart_refused "the environment was saved, but the rolling restart was refused — retry"

  @ensure_env_refused "the environment was saved, but the deployment could not be updated to consume it — retry"

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&prepare/1)
    |> Ash.Changeset.after_action(&apply_secret/2)
    |> Ash.Changeset.after_transaction(&finish/2)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (a locked read and K8s I/O live in the hooks)
  def atomic?, do: false

  # ------------------------------------------------------------------
  # before_action — lock, guard, merge, stash
  # ------------------------------------------------------------------

  defp prepare(changeset) do
    Process.delete(@stash_key)

    case lock_row(changeset.data.id) do
      {:ok, %Instance{} = row} ->
        prepare_row(changeset, row)

      # coveralls-ignore-start - the teardown race: the row died
      # between the changeset's load and this locked read (#86's race
      # window; ExUnit cannot stage it deterministically).
      {:ok, nil} ->
        Ash.Changeset.add_error(
          changeset,
          "the instance no longer exists — retry from a fresh read"
        )

      # coveralls-ignore-stop

      # coveralls-ignore-start - defensive: the locked read's DB-outage
      # class, ExUnit cannot stage it (DBConnection reconnects by
      # design).
      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
        # coveralls-ignore-stop
    end
  end

  defp prepare_row(changeset, row) do
    changeset = %{changeset | data: row}

    with :ok <- status_guard(row),
         {:ok, version} <- load_version(row),
         {:ok, plan} <- patch_plan(changeset, row, version),
         plan = compose_allowlist(plan, row, version),
         :ok <- validate_merged(plan.merged, version),
         noop = noop?(plan),
         {:ok, target} <- apply_target(row, noop) do
      Process.put(@stash_key, %{
        set: plan.set,
        remove: plan.remove,
        skipped: plan.skipped,
        added: plan.added,
        changed: plan.changed,
        removed: plan.removed,
        composed: plan.composed,
        expect_existing: map_size(row.env_vars) > 0,
        noop: noop,
        status: row.status,
        kubeconfig: target.kubeconfig,
        namespace: target.namespace
      })

      Ash.Changeset.force_change_attribute(changeset, :env_vars, plan.merged)
    else
      {:error, %InvalidArgument{} = error} ->
        Ash.Changeset.add_error(changeset, error)

      # ValidateEnvVars.check/2 returns a bare InvalidAttribute for a
      # stored row with a non-string value; the general exception
      # clause keeps that an honest error, never a WithClauseError.
      {:error, %{__exception__: true} = error} ->
        Ash.Changeset.add_error(changeset, error)

      {:error, errors} when is_list(errors) ->
        Ash.Changeset.add_error(changeset, errors)
    end
  end

  defp lock_row(instance_id) do
    Instance
    |> Ash.Query.filter(id == ^instance_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp status_guard(%Instance{status: status}) when status in @updatable, do: :ok

  defp status_guard(%Instance{status: :deleting}) do
    {:error,
     InvalidArgument.exception(
       message: "the instance is being deleted — there is nothing to update"
     )}
  end

  defp status_guard(%Instance{status: status}) when status in @busy do
    {:error,
     InvalidArgument.exception(
       message: "the instance is busy (#{status}) — retry when it settles"
     )}
  end

  # coveralls-ignore-start - defensive: the status type is closed today;
  # a new status must add an explicit rule rather than fall through.
  defp status_guard(%Instance{status: status}) do
    {:error, InvalidArgument.exception(message: "cannot update env in #{status} state")}
  end

  # coveralls-ignore-stop

  defp load_version(row) do
    case Ash.load(row, :app_version, authorize?: false) do
      {:ok, %{app_version: version}} ->
        {:ok, version}

      # coveralls-ignore-start - defensive: a DB read failure here is
      # the outage class ExUnit cannot stage.
      {:error, _reason} ->
        {:error, InvalidArgument.exception(message: "the app version could not be read — retry")}
        # coveralls-ignore-stop
    end
  end

  defp patch_plan(changeset, row, version) do
    set = Ash.Changeset.get_argument(changeset, :set)
    remove = Ash.Changeset.get_argument(changeset, :remove)
    fixed = EnvPatch.fixed_keys(version.first_run)
    forbidden = EnvPatch.forbidden_keys(version.first_run)

    with {:ok, wired?} <- wired(row.id) do
      owned = EnvPatch.owned_keys(row, version, wired?)
      plan_or_error(row.env_vars, set, remove, owned, fixed, forbidden)
    end
  end

  defp plan_or_error(current_env, set, remove, owned, fixed, forbidden) do
    case EnvPatch.plan(current_env, set, remove, owned, fixed, forbidden) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:error, InvalidArgument.exception(message: EnvPatch.message(reason))}
    end
  end

  # A wiring row means the recipe's keys are platform-composed above
  # user env; without one they are ordinary user keys (a pre-wire set
  # is still the user's — the operation refuses to override it). Only
  # a NotFound miss is "not wired": any other read failure must fail
  # closed, never classify the platform's SSO keys as user-owned.
  defp wired(instance_id) do
    case PocketIdWiring.get_by_instance(instance_id, authorize?: false) do
      {:ok, _wiring} ->
        {:ok, true}

      {:error, error} ->
        if not_found?(error) do
          {:ok, false}
        else
          {:error,
           InvalidArgument.exception(
             message: "the instance's SSO wiring could not be read — retry"
           )}
        end
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_other), do: false

  # The allowlist key stays user-writable, but the platform hostname
  # must survive any patch that touches it: compose the deployer's
  # append for the LIVE Secret only (one shared helper) and carry that
  # value in `set` while the row keeps the user's exact map. Writing
  # the composed value to the row would make the next deploy append the
  # hostname again, and a stale host would survive an unclaim.
  #
  # A public remove-only patch re-adds the platform entry — the key
  # leaves the remove list, the platform's value lands in `set`. A
  # private, non-live row has no platform entry: the helper leaves the
  # map unchanged, so a remove really removes the key.
  defp compose_allowlist(plan, row, version) do
    env_name = version.host_allowlist_env

    if is_binary(env_name) and
         (Map.has_key?(plan.set, env_name) or env_name in plan.remove) do
      composed = InstanceEnvDerived.allowlist_entry(plan.merged, row, version)
      before = Map.get(plan.merged, env_name)

      case Map.fetch(composed, env_name) do
        {:ok, ^before} ->
          plan

        {:ok, value} ->
          %{
            plan
            | set: Map.put(plan.set, env_name, value),
              remove: List.delete(plan.remove, env_name),
              composed: [env_name]
          }

        :error ->
          plan
      end
    else
      plan
    end
  end

  # The final EFFECT, after the allowlist projection: a same-value set
  # or an already-absent remove changes nothing, so no Secret write and
  # no rollout are owed. An explicit applied removal always reaches the
  # Secret — the row may lack a key that drift left live-only.
  defp noop?(plan) do
    plan.added == [] and plan.changed == [] and plan.removed == [] and
      plan.remove == [] and plan.composed == []
  end

  defp apply_target(_row, true), do: {:ok, %{kubeconfig: nil, namespace: nil}}
  defp apply_target(row, false), do: apply_target(row)

  defp validate_merged(merged, version) do
    ValidateEnvVars.check(merged, version.configurable_env_vars || %{})
  end

  # The row-only statuses reach no cluster. The four deployed statuses
  # stash the kubeconfig/namespace for the hook pair below. A nil
  # namespace on a deployed status is a broken row (the state machine
  # pins it at deploy) — refuse rather than call K8s with nil.
  defp apply_target(%Instance{status: status}) when status in @row_only,
    do: {:ok, %{kubeconfig: nil, namespace: nil}}

  defp apply_target(%Instance{namespace: nil}) do
    {:error,
     InvalidArgument.exception(
       message: "the instance has no live namespace — retry after a deploy"
     )}
  end

  defp apply_target(%Instance{status: status} = row) when status in @deployed do
    case InstanceK8s.kubeconfig_for(row) do
      {:ok, kubeconfig} ->
        {:ok, %{kubeconfig: kubeconfig, namespace: row.namespace}}

      {:error, _reason} ->
        {:error,
         InvalidArgument.exception(
           message: "the cluster is unreachable — nothing was changed; retry"
         )}
    end
  end

  # ------------------------------------------------------------------
  # after_action — the Secret, inside the row transaction
  # ------------------------------------------------------------------

  defp apply_secret(_changeset, instance) do
    case Process.get(@stash_key) do
      %{noop: true} ->
        {:ok, instance}

      %{kubeconfig: nil} ->
        {:ok, instance}

      %{
        kubeconfig: kubeconfig,
        namespace: namespace,
        set: set,
        remove: remove,
        expect_existing: expect_existing
      } ->
        case InstanceEnvSecret.upsert(kubeconfig, namespace, set, remove, expect_existing) do
          :ok -> {:ok, instance}
          {:error, reason} -> {:error, secret_error(reason)}
        end

      # coveralls-ignore-start - defensive: a success always stashes
      # in prepare/1; only a change in hook registration could reach
      # here.
      nil ->
        {:ok, instance}
        # coveralls-ignore-stop
    end
  end

  defp secret_error(:missing) do
    InvalidArgument.exception(
      message: "the instance's live env Secret is missing — redeploy to repair"
    )
  end

  defp secret_error(%K8s.Error{status_code: status, reason: reason}) do
    InvalidArgument.exception(
      message:
        "the live environment could not be updated (Kubernetes #{status} #{reason}) — nothing was changed; retry"
    )
  end

  # ------------------------------------------------------------------
  # after_transaction — cleanup, audit log, post-commit restart
  # ------------------------------------------------------------------

  defp finish(changeset, result) do
    stash = Process.delete(@stash_key) || %{}

    case result do
      {:ok, instance} ->
        log_update(changeset, instance, stash)

        case ensure_env_consumed(stash) do
          :ok ->
            restart_live(instance, stash, result)

          {:error, _reason} ->
            {:error, InvalidArgument.exception(message: @ensure_env_refused)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # stopped/sleeping pods are absent: the row + Secret are committed and
  # the next start reads the Secret, but the Deployment must first
  # consume it. Only a pre-merge empty row can lack the envFrom (the
  # live statuses' restart already ensures it; a no-op owes no cluster
  # work).
  defp ensure_env_consumed(%{
         status: status,
         noop: false,
         expect_existing: false,
         kubeconfig: kubeconfig,
         namespace: namespace
       })
       when status in @secret_only do
    InstanceEnvSecret.ensure_env_from(kubeconfig, namespace)
  end

  defp ensure_env_consumed(_stash), do: :ok

  # Key NAMES only — never a value (ADR-0052 decision 6).
  defp log_update(changeset, instance, stash) do
    actor = changeset.context[:private][:actor]

    Logger.info(
      "instance env updated instance=#{instance.id} actor=#{actor_id(actor)} " <>
        "added=#{inspect(names(stash, :added))} changed=#{inspect(names(stash, :changed))} " <>
        "removed=#{inspect(names(stash, :removed))} skipped=#{inspect(names(stash, :skipped))} " <>
        "composed=#{inspect(names(stash, :composed))}"
    )
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_none), do: nil

  defp names(stash, key), do: Map.get(stash, key, [])

  defp restart_live(_instance, %{noop: true}, result), do: result

  defp restart_live(
         _instance,
         %{status: status, kubeconfig: kubeconfig, namespace: namespace},
         result
       )
       when status in @live do
    case InstanceEnvSecret.restart(kubeconfig, namespace) do
      :ok -> result
      {:error, _reason} -> {:error, InvalidArgument.exception(message: @restart_refused)}
    end
  end

  defp restart_live(_instance, _stash, result), do: result
end

defmodule FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv do
  @moduledoc """
  Re-tells a deployed app its address after an address event: recompute
  the URL env key (and the host-allowlist append) from the one
  derivation (`InstanceEnvDerived.derive/1` — ADR-0052's seam, this
  being its third consumer), compare against the live `app-env` Secret,
  and write + roll only on a real change. No-op when nothing differs —
  no write, no restart.

  The sync owns its transaction, mirroring the in-place env action's
  split legs (`Instance.UpdateEnv`): the row is locked `FOR UPDATE`,
  then everything downstream re-derives from the locked row — status
  gate, version, facts, kubeconfig, namespace, the live Secret read,
  and the key changes. That order is the safety story: the allowlist
  append composes ONTO the live Secret's value, so it must compose
  under the same lock that serializes a concurrent user PATCH —
  composing before the lock would merge a stale snapshot over the
  user's edit inside `InstanceEnvSecret.upsert/5`. The upsert runs
  inside the transaction; the rolling restart runs after it commits.
  `InstanceEnvSecret.apply_locked/4` is deliberately not used — it
  restarts inside the transaction and composes nothing; the sync needs
  the opposite split, and the seam provides the legs (`upsert/5`,
  `restart/2`, `ensure_env_from/2`).

  Status dispatch mirrors `Instance.UpdateEnv`'s discipline: live rows
  (`running`/`starting`/`no_capacity`) get the post-commit rolling
  restart; stopped/sleeping rows get no restart, plus the spec-only
  `ensure_env_from/2` when this call created the Secret; the busy
  (`deploying`/`restoring`), row-only (`pending`/`error`/`lost`), and
  deleting statuses skip with zero cluster calls — the next
  deploy/restore composes the env from the same derivation, so
  skipping converges by construction.

  The instance row is never written. The URL key is a live-Secret
  projection composed above user env (a redeploy recomposes it from the
  same derivation); the allowlist entry is append-only onto the live
  value — a host that stops serving stays harmless in ALLOWED_HOSTS,
  and the next live address overwrites the URL key.

  Errors return `{:error, term()}`: `:not_deployed` (a gated row with
  no namespace — a broken row), `:missing` (a deployed row whose Secret
  is gone — the seam's "redeploy to repair" stance; the row's env, or
  its bundled backing services, say a Secret exists), the k8s calls'
  own error tuples, and read failures from the locked-row/version
  reads (the DB-outage class). A vanished instance is `:ok` — teardown
  won, nothing to tell. A failed post-commit restart returns the error
  with the Secret already written — the new values staged, the pods
  still on the old env. The next address event that changes the values
  re-derives and rolls, and a redeploy recomposes everything; a
  value-identical retry is a no-op by design (the no-op gate), the
  same posture the public env action documents for its restart gap
  (`Instance.UpdateEnv`). Callers own the event semantics (a later
  slice wires the events).
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceEnvDerived
  alias FluxVale.Infrastructure.Operations.InstanceEnvSecret
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Repo

  require Ash.Query

  @env_secret "app-env"

  # The UpdateEnv status discipline (resources/instance/update_env.ex):
  # anything outside these two lists skips with zero cluster calls.
  @live [:running, :starting, :no_capacity]
  @secret_only [:stopped, :sleeping]

  @doc """
  Re-tells a deployed app its address after an address event: recompute
  the URL env key (and the host-allowlist append) from the one
  derivation, compare against the live app-env Secret, and write + roll
  only on a real change. No-op when nothing differs — no write, no
  restart. The instance row is never written (the URL key is a live
  Secret projection; a redeploy recomposes it from the same derivation).
  """
  @spec call(Instance.t() | Ash.UUID.t()) :: :ok | {:error, term()}
  def call(instance_or_id) do
    id = instance_id(instance_or_id)

    case Repo.transaction(fn -> locked_sync(id) end) do
      {:ok, :ok} -> :ok
      {:ok, {:apply, leg, kubeconfig, namespace}} -> apply_leg(leg, kubeconfig, namespace)
      {:error, reason} -> {:error, reason}
    end
  end

  defp instance_id(%Instance{} = instance), do: instance.id
  defp instance_id(id) when is_binary(id), do: id

  defp locked_sync(id) do
    case lock_row(id) do
      {:ok, %Instance{} = locked} ->
        sync_locked(locked)

      # Teardown won between the event and this read: nothing to tell.
      {:ok, nil} ->
        :ok

      # coveralls-ignore-start - defensive: the locked read's DB-outage
      # class, ExUnit cannot stage it (DBConnection reconnects by
      # design).
      {:error, reason} ->
        Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  # The row lock the public env action takes (AdoptCurrentRow's
  # serialization stance) — the same shape InstanceEnvSecret uses, so
  # a racing deploy/PATCH/SSO write serializes against this whole
  # compose+upsert.
  defp lock_row(instance_id) do
    Instance
    |> Ash.Query.filter(id == ^instance_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp sync_locked(locked) do
    case Ash.load(locked, [:app_version, :backing_services], authorize?: false) do
      {:ok, %{app_version: version}} ->
        gated_sync(locked, version)

      # coveralls-ignore-start - defensive: the DB-outage class ExUnit
      # cannot stage (DBConnection reconnects by design). NotFound
      # cannot happen here (the version FK is required) — every failure
      # is a read failure, and callers own the retry.
      {:error, reason} ->
        Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  # The two zero-cluster gates, in order: a version naming neither env
  # key owes no address env; a busy, row-only, or deleting status owes
  # nothing either. Both re-decide under the lock: a status that moved
  # mid-flight lands here, not on the caller's stale snapshot.
  defp gated_sync(locked, version) do
    cond do
      not declared?(version) -> :ok
      not proceed?(locked) -> :ok
      true -> compose_and_upsert(locked, version)
    end
  end

  defp declared?(version),
    do: is_binary(version.instance_url_env) or is_binary(version.host_allowlist_env)

  defp proceed?(%Instance{status: status}),
    do: status in @live or status in @secret_only

  # One snapshot feeds both keys, composed under the row lock. Kubeconfig
  # first, then the namespace: the gates admit only deployed rows, so a
  # nil namespace here is a broken row — the seam's own refusal shape,
  # never a nil-crash into the cluster calls.
  defp compose_and_upsert(locked, version) do
    facts = InstanceEnvDerived.derive(locked)

    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(locked),
         {:ok, namespace} <- namespace(locked),
         {live_data, existed?} when is_map(live_data) and is_boolean(existed?) <-
           live_data(kubeconfig, namespace, locked) do
      {set, remove} = key_changes(version, facts, live_data)

      if set == %{} and remove == [] do
        # The lane's explicit idempotency contract: nothing differs —
        # no write, no restart, no ensure.
        :ok
      else
        upsert_locked(locked, kubeconfig, namespace, set, remove, existed?)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp namespace(%Instance{namespace: ns}) when is_binary(ns), do: {:ok, ns}
  defp namespace(%Instance{}), do: {:error, :not_deployed}

  # The live value this call composes onto, and whether the Secret
  # existed (a newly created one owes the stopped/sleeping ensure). A
  # gated row whose Secret is gone is a broken state — writing only
  # this call's keys would boot the app without its other env — the
  # seam's "redeploy to repair" stance, never a partial merge. An
  # env-less row with no bundled backing services has nothing to lose:
  # start from %{}.
  defp live_data(kubeconfig, namespace, instance) do
    case Secret.get_data(kubeconfig, namespace, @env_secret) do
      {:ok, data} ->
        {data, true}

      {:error, %K8s.Error{reason: :not_found}}
      when instance.env_vars == %{} and instance.backing_services == [] ->
        {%{}, false}

      {:error, %K8s.Error{reason: :not_found}} ->
        {:error, :missing}

      {:error, _other} = error ->
        error
    end
  end

  # Whether the live Secret should already exist. The row's env is the
  # usual answer — but a bundled-backing version's deploy seeds app-env
  # from the backing URLs alone (`DeployInstance.put_backing_urls`
  # composes every declared url_env into the env), so an env-less row
  # with declared services expects one too: a drifted-away Secret there
  # is a broken state, refused — never rebuilt partial.
  defp expect_existing?(instance) do
    instance.env_vars != %{} or instance.backing_services != []
  end

  defp upsert_locked(locked, kubeconfig, namespace, set, remove, existed?) do
    # The row is never written here, so the row itself answers whether
    # the Secret should already exist.
    expect_existing = expect_existing?(locked)

    case InstanceEnvSecret.upsert(kubeconfig, namespace, set, remove, expect_existing) do
      :ok ->
        cond do
          locked.status in @live ->
            {:apply, :restart, kubeconfig, namespace}

          not existed? ->
            # stopped/sleeping pods are absent: only a Secret this call
            # created owes the spec-only ensure; the next start reads it.
            {:apply, :ensure, kubeconfig, namespace}

          true ->
            :ok
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Post-commit: the rolling restart for live rows; the spec-only
  # ensure for a Secret this call created on stopped/sleeping rows.
  # A refusal here leaves the Secret written and returns the error —
  # the new values staged, the pods still on the old env. A retry that
  # changes nothing is a no-op by design (the no-op gate): the next
  # changing address event re-derives and rolls; a redeploy recomposes.
  defp apply_leg(:restart, kubeconfig, namespace) do
    InstanceEnvSecret.restart(kubeconfig, namespace)
  end

  defp apply_leg(:ensure, kubeconfig, namespace) do
    InstanceEnvSecret.ensure_env_from(kubeconfig, namespace)
  end

  # The ONE facts snapshot feeds both keys; set/remove carry ONLY the
  # computed keys.
  defp key_changes(version, facts, live_data) do
    {url_set, url_remove} = url_changes(version.instance_url_env, facts.url, live_data)
    allow_set = allowlist_change(version, facts.hostnames, live_data)

    {Map.merge(url_set, allow_set), url_remove}
  end

  # The URL key: the snapshot's URL lands verbatim — but a value the
  # live Secret already carries is not a change (the lane's no-op
  # contract); a nil URL removes the key, only when the live Secret
  # carries it (a removal on an absent key is a no-op).
  defp url_changes(env_name, _url, _live_data) when is_nil(env_name), do: {%{}, []}

  defp url_changes(env_name, nil, live_data) do
    if Map.has_key?(live_data, env_name) do
      {%{}, [env_name]}
    else
      {%{}, []}
    end
  end

  defp url_changes(env_name, url, live_data) do
    if Map.get(live_data, env_name) == url do
      {%{}, []}
    else
      {%{env_name => url}, []}
    end
  end

  # The allowlist key: the platform's append onto the LIVE value — the
  # append's own dedupe makes repeats no-ops, and an unchanged value
  # writes nothing.
  defp allowlist_change(version, _hostnames, _live_data)
       when is_nil(version.host_allowlist_env),
       do: %{}

  defp allowlist_change(version, hostnames, live_data) do
    env_name = version.host_allowlist_env
    composed = InstanceEnvDerived.allowlist_entry(live_data, hostnames, version)
    value = Map.get(composed, env_name)

    if value == Map.get(live_data, env_name) do
      %{}
    else
      %{env_name => value}
    end
  end
end

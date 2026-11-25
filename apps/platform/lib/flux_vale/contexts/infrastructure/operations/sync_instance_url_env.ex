defmodule FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv do
  @moduledoc """
  Re-tells a deployed app its address after an address event: recompute
  the URL env key (and the host-allowlist append) from the one
  derivation (`InstanceEnvDerived.derive/1` — ADR-0052's seam, this
  being its third consumer), compare against the live `app-env` Secret,
  and write + roll only on a real change. No-op when nothing differs —
  no write, no restart.

  Status dispatch mirrors the in-place env action's discipline
  (`Instance.UpdateEnv`): live rows (`running`/`starting`/
  `no_capacity`) ride `InstanceEnvSecret.apply_locked/4` — the row lock
  serializes against a racing deploy/PATCH/SSO write; stopped/sleeping
  rows ride `upsert/5` with no restart, plus the spec-only
  `ensure_env_from/2` when this call created the Secret; the busy
  (`deploying`/`restoring`/`deleting`) and row-only
  (`pending`/`error`/`lost`) statuses skip with zero cluster calls —
  the next deploy/restore composes the env from the same derivation,
  so skipping converges by construction.

  The instance row is never written. The URL key is a live-Secret
  projection composed above user env (a redeploy recomposes it from the
  same derivation); the allowlist entry is append-only onto the live
  value — a host that stops serving stays harmless in ALLOWED_HOSTS,
  and the next live address overwrites the URL key.

  Errors return `{:error, term()}`; callers own the event semantics (a
  later slice wires the address events to this call).
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceEnvDerived
  alias FluxVale.Infrastructure.Operations.InstanceEnvSecret
  alias FluxVale.Infrastructure.Operations.InstanceK8s

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

    case Instance.get_by_id(id, authorize?: false) do
      {:ok, %Instance{} = fresh} ->
        sync(fresh)

      # Teardown won between the event and this read: nothing to tell.
      {:error, _vanished} ->
        :ok
    end
  end

  defp instance_id(%Instance{} = instance), do: instance.id
  defp instance_id(id) when is_binary(id), do: id

  defp sync(fresh) do
    case Ash.load(fresh, :app_version, authorize?: false) do
      {:ok, %{app_version: version}} ->
        gated_sync(fresh, version)

      # coveralls-ignore-start - defensive: the DB-outage class ExUnit
      # cannot stage (DBConnection reconnects by design). No version, no
      # env names to manage — the same degrade-to-bare stance the
      # deploy's own derivation takes; the next event re-reads.
      {:error, _read_failed} ->
        :ok
        # coveralls-ignore-stop
    end
  end

  # The two zero-cluster gates, in order: a version naming neither env
  # key owes no address env; a busy or row-only status owes nothing
  # either.
  defp gated_sync(fresh, version) do
    cond do
      not declared?(version) -> :ok
      not proceed?(fresh) -> :ok
      true -> apply_address(fresh, version)
    end
  end

  defp declared?(version),
    do: is_binary(version.instance_url_env) or is_binary(version.host_allowlist_env)

  defp proceed?(%Instance{status: status}),
    do: status in @live or status in @secret_only

  # One snapshot feeds both keys. Kubeconfig first, then the namespace:
  # the gates admit only deployed rows, so a nil namespace here is a
  # broken row — the seam's own refusal shape, never a nil-crash into
  # the cluster calls.
  defp apply_address(fresh, version) do
    facts = InstanceEnvDerived.derive(fresh)

    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(fresh),
         {:ok, namespace} <- namespace(fresh),
         {live_data, existed?} when is_map(live_data) and is_boolean(existed?) <-
           live_data(kubeconfig, namespace, fresh) do
      apply_changes(kubeconfig, namespace, fresh, version, facts, live_data, existed?)
    end
  end

  defp namespace(%Instance{namespace: ns}) when is_binary(ns), do: {:ok, ns}
  defp namespace(%Instance{}), do: {:error, :not_deployed}

  # The live value this call composes onto, and whether the Secret
  # existed (a newly created one owes the stopped/sleeping ensure). A
  # deployed row with env whose Secret is gone is a broken state —
  # writing only this call's keys would boot the app without its other
  # env — the seam's "redeploy to repair" stance, never a partial
  # merge. An env-less row has nothing to lose: start from %{}.
  defp live_data(kubeconfig, namespace, fresh) do
    case Secret.get_data(kubeconfig, namespace, @env_secret) do
      {:ok, data} ->
        {data, true}

      {:error, %K8s.Error{reason: :not_found}} when fresh.env_vars == %{} ->
        {%{}, false}

      {:error, %K8s.Error{reason: :not_found}} ->
        {:error, :missing}

      {:error, _other} = error ->
        error
    end
  end

  defp apply_changes(kubeconfig, namespace, fresh, version, facts, live_data, existed?) do
    {set, remove} = key_changes(version, facts, live_data)
    expect_existing = fresh.env_vars != %{}

    cond do
      # The lane's explicit idempotency contract: nothing differs — no
      # write, no restart.
      set == %{} and remove == [] ->
        :ok

      fresh.status in @live ->
        # The row is never written here, so the row itself answers
        # whether the Secret should already exist.
        InstanceEnvSecret.apply_locked(fresh, set, remove, expect_existing)

      true ->
        secret_only_apply(kubeconfig, namespace, set, remove, expect_existing, existed?)
    end
  end

  # Stopped/sleeping: pods are absent — the Secret lands now, the next
  # start reads it, and no rollout is owed.
  defp secret_only_apply(kubeconfig, namespace, set, remove, expect_existing, existed?) do
    with :ok <-
           InstanceEnvSecret.upsert(kubeconfig, namespace, set, remove, expect_existing) do
      maybe_ensure_env(kubeconfig, namespace, existed?)
    end
  end

  # The spec-only ensure: only a Secret this call created owes it (an
  # existing Secret already has its consuming Deployment).
  defp maybe_ensure_env(_kubeconfig, _namespace, true), do: :ok

  defp maybe_ensure_env(kubeconfig, namespace, false) do
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

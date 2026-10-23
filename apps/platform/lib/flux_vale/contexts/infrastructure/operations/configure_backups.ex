defmodule FluxVale.Infrastructure.Operations.ConfigureBackups do
  @moduledoc """
  Saves an Instance's backup destination (#222, ADR-0037): composes the
  restic repo URL, get-or-creates the namespace's `backup-config` Secret,
  widens the namespace ResourceQuota by the backup Job's requests, then
  upserts the `BackupSetting` row.

  Order is the contract. The Secret and the quota are the cluster state
  the backup Job runs on; the row merely records them. A K8s failure
  therefore returns `{:error, reason}` and writes **no** row — a saved
  setting that can't back up is worse than a visible failure.

  Ownership is enforced up front by the actor-authorized `get_by_id`
  read, v1's `delete` shape: a non-member is `Forbidden` before any
  cluster write, not after.

  **Disabling is a plain `BackupSetting.update` (`enabled: false`), not an
  operation of its own** — it changes one attribute and no cluster state.
  The Secret and the quota margin persist on purpose, so re-enabling
  reuses the same restic repo: a regenerated `RESTIC_PASSWORD` would
  orphan every snapshot already in the user's bucket (ADR-0037 §4).

  The repo password is generated once, at first save (32 bytes CSPRNG,
  URL-safe base64 — the #190 recipe), and never rotated: a re-save with
  new S3 credentials preserves the existing one byte-for-byte. Neither
  the S3 secret key nor the repo password reaches the platform DB, and
  nothing secret is logged.
  """

  # The `get_by_id` failure shapes are structural, not semantic: a
  # missing row and a filtered-out row both arrive as this class.
  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias Ash.Error.Query.NotFound
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @secret_name "backup-config"
  @quota_name "app-quota"
  @repo_key "RESTIC_REPOSITORY"
  @password_key "RESTIC_PASSWORD"
  @access_key_id_key "AWS_ACCESS_KEY_ID"
  @secret_access_key_key "AWS_SECRET_ACCESS_KEY"

  # The row's own fields — the settings form, minus every credential.
  @row_fields [:endpoint, :bucket, :prefix, :access_key_id, :retention_keep, :enabled]

  @typedoc """
  The settings form: bucket coordinates plus the S3 secret key (input
  only — it goes to the namespace Secret, never to the row).
  """
  @type params :: %{
          required(:endpoint) => String.t(),
          required(:bucket) => String.t(),
          required(:access_key_id) => String.t(),
          optional(:prefix) => String.t() | nil,
          optional(:secret_access_key) => String.t(),
          optional(:retention_keep) => integer(),
          optional(:enabled) => boolean()
        }

  @doc """
  Applies the settings for `instance`. `opts` carry the caller's `actor:`
  and `authorize?:` — the instance is re-read through the authorized
  `get_by_id`, so an outsider is `Forbidden` before any cluster write.
  """
  @spec call(map(), params(), keyword()) :: {:ok, BackupSetting.t()} | {:error, term()}
  def call(instance, params, opts \\ []) do
    with {:ok, authorized} <- authorize_instance(instance, opts),
         {:ok, kubeconfig} <- kubeconfig(authorized),
         {:ok, data} <- secret_data(kubeconfig, authorized, params),
         :ok <- apply_secret(kubeconfig, authorized, data),
         :ok <- apply_quota(kubeconfig, authorized) do
      upsert_row(authorized, params, opts)
    end
  end

  # Ownership first, and a write answers Forbidden where a read would
  # merely filter: a non-member's save must not read as "missing" — the
  # UI would offer to recreate an instance that exists under someone
  # else's org. The unauthorized re-read only tells "not yours" apart
  # from "gone" on the failure path.
  defp authorize_instance(instance, opts) do
    case Instance.get_by_id(instance.id, opts) do
      {:ok, authorized} ->
        {:ok, authorized}

      {:error, %Invalid{errors: [%NotFound{}]}} ->
        not_owned_or_missing(instance, opts)

      # coveralls-ignore-start - defensive: the only other read failure is
      # a DB outage, which ExUnit cannot simulate (DBConnection reconnects)
      {:error, _error} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp not_owned_or_missing(instance, opts) do
    case Instance.get_by_id(instance.id, Keyword.put(opts, :authorize?, false)) do
      {:ok, _existing} ->
        {:error, Forbidden.exception([])}

      # coveralls-ignore-start - defensive: a row deleted between the two
      # reads is a race ExUnit can't stage deterministically; the plain
      # NotFound is the honest answer when it happens.
      {:error, _error} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # Never deployed: no namespace, so no Secret to write and no quota to
  # widen. Checked after the ownership read — a stranger learns nothing.
  defp kubeconfig(%{namespace: nil}), do: {:error, :not_deployed}
  defp kubeconfig(instance), do: InstanceK8s.kubeconfig_for(instance)

  # Get-or-create, never blind-apply: an existing Secret is the repo's
  # identity — its password survives every save or the snapshots do not.
  defp secret_data(kubeconfig, instance, params) do
    case Secret.get_data(kubeconfig, instance.namespace, @secret_name) do
      {:ok, existing} ->
        password = existing[@password_key] || generate_password()
        secret_key = Map.get(params, :secret_access_key) || existing[@secret_access_key_key]
        {:ok, data_for(params, password, secret_key)}

      {:error, %Error{reason: :not_found}} ->
        fresh_secret_data(params, Map.get(params, :secret_access_key))

      {:error, error} ->
        {:error, error}
    end
  end

  # First save has no stored key to fall back on — the form must supply
  # the S3 secret, since the Job cannot authenticate without it.
  defp fresh_secret_data(_params, nil), do: {:error, :secret_access_key_required}

  defp fresh_secret_data(params, secret_key) do
    {:ok, data_for(params, generate_password(), secret_key)}
  end

  defp data_for(params, password, secret_key) do
    %{
      @repo_key => repo_url(params),
      @password_key => password,
      @access_key_id_key => params.access_key_id,
      @secret_access_key_key => secret_key
    }
  end

  # restic's S3 shape: "s3:" <> endpoint "/" bucket ["/" prefix]. The
  # endpoint's trailing slash is legal input, not part of the join.
  defp repo_url(params) do
    base = String.trim_trailing(params.endpoint, "/") <> "/" <> params.bucket

    case Map.get(params, :prefix) do
      nil -> "s3:" <> base
      prefix -> "s3:" <> base <> "/" <> prefix
    end
  end

  # 32 bytes of CSPRNG entropy, URL-safe base64 (43 chars) — restic
  # accepts any string; this keeps it copy-paste safe for a restore
  # after the instance is gone (ADR-0037 §4).
  defp generate_password do
    entropy = :crypto.strong_rand_bytes(32)
    Base.url_encode64(entropy, padding: false)
  end

  defp apply_secret(kubeconfig, instance, data) do
    case Secret.create(kubeconfig, instance.namespace, @secret_name, data) do
      {:ok, _secret} -> :ok
      {:error, _error} = error -> error
    end
  end

  # The backup Job runs in the instance namespace, so its requests must
  # fit the ResourceQuota (ADR-0037 §3). Same arithmetic as the #190
  # sidecar margin in DeployInstance — the quota is an absolute apply, so
  # both writers compute the same total: allocation + platform overhead.
  # Harmless headroom while disabled: a re-enable then needs no quota
  # write to start backing up.
  defp apply_quota(kubeconfig, instance) do
    case ResourceQuota.create(kubeconfig, instance.namespace, @quota_name, quota_spec(instance)) do
      {:ok, _quota} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp quota_spec(instance) do
    base = allocation(instance)
    sidecar = maybe_sidecar(instance, base)
    final = backup_margin(sidecar)
    {cpu, memory} = final

    %{cpu: cpu, memory: memory, storage: instance.storage_gb}
  end

  defp allocation(instance), do: {instance.cpu_cores, instance.memory_mb}

  # File access is overhead only when there is a volume to serve — the
  # same gate DeployInstance applies (a 0 GB instance gets no sidecar and
  # no margin). Decimal, not float: the sum must not round below the
  # pod's exact request.
  defp maybe_sidecar(%{file_access: true, storage_gb: gb}, {cpu, memory}) when gb > 0 do
    {Decimal.add(cpu, Decimal.new("0.05")), memory + 64}
  end

  defp maybe_sidecar(_instance, totals), do: totals

  # Requests from config (:backups) — the Job spec in a later slice reads
  # the same block, so quota and Job cannot disagree.
  defp backup_margin({cpu, memory}) do
    config = Application.fetch_env!(:flux_vale, :backups)
    job_cpu = Decimal.new(config[:cpu_cores])
    cpu_request = Decimal.add(cpu, job_cpu)

    {cpu_request, memory + config[:memory_mb]}
  end

  defp upsert_row(instance, params, opts) do
    attrs = row_attrs(params)

    case BackupSetting.get_by_instance(instance.id, opts) do
      {:ok, setting} ->
        update_row(setting, attrs, opts)

      {:error, %Invalid{errors: [%NotFound{}]}} ->
        create_row(instance, attrs, opts)

      # coveralls-ignore-start - defensive: the only other read failure is
      # a DB outage, which ExUnit cannot simulate (DBConnection reconnects)
      {:error, _error} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp update_row(setting, attrs, opts) do
    setting
    |> Ash.Changeset.for_update(:update, attrs, opts)
    |> Ash.update()
  end

  defp create_row(instance, attrs, opts) do
    attrs = Map.put(attrs, :instance_id, instance.id)

    BackupSetting
    |> Ash.Changeset.for_create(:create, attrs, opts)
    |> Ash.create()
  end

  # prefix: nil is meaningful (clear it); every other nil is "not in this
  # save", so the attribute keeps its default or stored value.
  defp row_attrs(params) do
    taken = Map.take(params, @row_fields)
    Map.reject(taken, fn {field, value} -> is_nil(value) and field != :prefix end)
  end
end

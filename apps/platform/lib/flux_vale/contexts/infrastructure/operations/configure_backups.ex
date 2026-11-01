defmodule FluxVale.Infrastructure.Operations.ConfigureBackups do
  @moduledoc """
  Saves an Instance's backup destination (#222, ADR-0037): merges the
  settings over the stored row, validates them, composes the restic repo
  URL, get-or-creates the namespace's `backup-config` Secret, widens the
  namespace ResourceQuota by the backup Job's requests, then writes the
  `BackupSetting` row.

  Order is the contract. Nothing touches the cluster until the merged
  settings validate: a typo'd bucket or a credential riding the endpoint
  returns `{:error, changeset}` with the Secret and the quota untouched.
  The Secret and the quota are the cluster state the backup Job runs on;
  the row merely records them. A K8s failure therefore returns `{:error,
  reason}` and writes **no** row — a saved setting that can't back up is
  worse than a visible failure.

  The Secret is written **before** the row on purpose: no Job can ever
  run against a repo the row doesn't know about. A double-submitted
  first save converges — the Secret apply is last-write-wins, the
  password lives only in the Secret, and no Job can reference it until
  the row exists (written once, after).

  Ownership is enforced up front by the actor-authorized `get_by_id`
  read, v1's `delete` shape: an actor always authorizes that read, even
  when the caller also passed `authorize?: false`, so a non-member is
  `Forbidden` before any cluster write and a hoisted instance struct
  buys nothing.

  A save that lands **enabled** is additionally pay-gated: the org must
  have PAID REAL MONEY once — one completed $1+ top-up, ever; the $3
  welcome credit is not a card (`ActorOrgHasPaid`). The gate sits after
  the changeset validates and before the first cluster touch, so a
  never-paid org's refusal leaves the Secret, the quota, and the row
  untouched. A save that lands `enabled: false` — a pause — passes
  through ungated, and disabling or removing the settings entirely is
  never gated at all.

  **Disabling is a plain `BackupSetting.update` (`enabled: false`), not
  an operation of its own** — it changes one attribute and no cluster
  state. The Secret and the quota margin persist on purpose, so
  re-enabling reuses the same restic repo: a regenerated
  `RESTIC_PASSWORD` would orphan every snapshot already in the user's
  bucket (ADR-0037 §4). Removing the settings entirely is
  `BackupSetting.destroy` — row only, same persistence stance.

  The repo password is generated once, at first save (32 bytes CSPRNG,
  URL-safe base64 — the #190 recipe), and never rotated: a re-save with
  new S3 credentials preserves the existing one byte-for-byte. Neither
  the S3 secret key nor the repo password reaches the platform DB, and
  nothing secret is logged.
  """

  # The `get_by_id` failure shapes are structural, not semantic: a
  # missing row and a filtered-out row both arrive as this class.
  alias Ash.Error.Forbidden
  alias Ash.Error.Forbidden.Policy
  alias Ash.Error.Invalid
  alias Ash.Error.Query.NotFound
  alias FluxVale.Checks.ActorOrgHasPaid
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
  @forbidden_message "This instance's backups belong to another organization"
  @paid_message "Top up at least $1 before setting up backups"

  # The row's own fields — the settings form, minus every credential.
  @row_fields [:endpoint, :bucket, :prefix, :access_key_id, :retention_keep, :enabled]

  @typedoc """
  The settings form: bucket coordinates plus the S3 secret key (input
  only — it goes to the namespace Secret, never to the row).

  A save is a partial update: omitted (`nil`) fields keep their stored
  value, `prefix: nil` clears the prefix, and `secret_access_key: ""`
  means "keep the stored key" (a blank form field). On a **first** save
  there is no stored row to merge, so `endpoint`, `bucket` and
  `access_key_id` are required — the changeset answers `{:error,
  changeset}` when one is missing. Every key is therefore optional at the
  type level: which ones are required is a question only the stored row
  can answer.
  """
  @type params :: %{
          optional(:endpoint) => String.t(),
          optional(:bucket) => String.t(),
          optional(:access_key_id) => String.t(),
          optional(:prefix) => String.t() | nil,
          optional(:secret_access_key) => String.t(),
          optional(:retention_keep) => integer(),
          optional(:enabled) => boolean()
        }

  @doc """
  Applies the settings for `instance`. `opts` carry the caller's `actor:`
  — the instance is re-read through the authorized `get_by_id`, so an
  outsider is `Forbidden` before any cluster write.
  """
  @spec call(map(), params(), keyword()) :: {:ok, BackupSetting.t()} | {:error, term()}
  def call(instance, params, opts \\ []) do
    opts = actor_authorized(opts)

    with {:ok, authorized} <- authorize_instance(instance, opts),
         {:ok, stored} <- stored_setting(authorized, opts),
         {:ok, changeset} <- settings_changeset(authorized, stored, params, opts),
         :ok <- paid_gate(authorized, changeset),
         {:ok, kubeconfig} <- kubeconfig(authorized),
         {:ok, data} <- secret_data(kubeconfig, authorized, changeset, params),
         :ok <- apply_secret(kubeconfig, authorized, data),
         :ok <- apply_quota(kubeconfig, authorized) do
      write_row(changeset)
    end
  end

  # An actor always authorizes: a caller can't pair a stranger's actor
  # with `authorize?: false` and a hoisted instance struct to slip past
  # the ownership read below. Callers with neither keep the internal
  # bypass (bootstrap paths only).
  defp actor_authorized(opts) do
    if opts[:actor], do: Keyword.delete(opts, :authorize?), else: opts
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

      {:error, %Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%NotFound{}, &1)) do
          not_owned_or_missing(instance, opts)
        else
          {:error, error}
        end

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
        {:error, Forbidden.exception(errors: [forbidden_error()])}

      # coveralls-ignore-start - defensive: a row deleted between the two
      # reads is a race ExUnit can't stage deterministically; the plain
      # NotFound is the honest answer when it happens.
      {:error, _error} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The policy error is the one Ash would produce on the write, carrying a
  # plain-words reason instead of a bare "forbidden".
  defp forbidden_error do
    Policy.exception(custom_message: @forbidden_message)
  end

  # The paid gate's error, same shape: the policy class carrying the
  # plain-words fix.
  defp paid_error do
    Policy.exception(custom_message: @paid_message)
  end

  # S3 backups are a paid feature: an enabled save (a first save
  # defaults enabled true; a re-enable rides a full save) needs one
  # real $1+ payment, ever — the welcome credit is not a card. The
  # predicate is authorize-free (the check IS the authorization, the
  # access panel's posture). A save that lands disabled passes through:
  # pausing is never gated. The gate runs before the first cluster
  # touch, so a refusal writes nothing anywhere.
  defp paid_gate(instance, changeset) do
    if Ash.Changeset.get_attribute(changeset, :enabled) do
      org_id = instance.organization_id

      if ActorOrgHasPaid.org_paid?(org_id) do
        :ok
      else
        {:error, Forbidden.exception(errors: [paid_error()])}
      end
    else
      :ok
    end
  end

  # The stored row is what a save merges over. Its own read is authorized
  # with the same opts, so a stranger never reaches the cluster with a
  # merge plan built from someone else's settings.
  defp stored_setting(instance, opts) do
    case BackupSetting.get_by_instance(instance.id, opts) do
      {:ok, setting} ->
        {:ok, setting}

      {:error, %Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%NotFound{}, &1)), do: {:ok, nil}, else: {:error, error}

      # coveralls-ignore-start - defensive: the only other read failure is
      # a DB outage, which ExUnit cannot simulate (DBConnection reconnects)
      {:error, _error} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # Validate before anything writes. The changeset carries the actor (so
  # the row write is policy-checked like the reads above it) and the
  # merged values (so an update is validated as the sum of stored + new,
  # not as the fragment the form sent).
  defp settings_changeset(instance, stored, params, opts) do
    attrs = merge_attrs(stored, params)

    changeset =
      case stored do
        nil ->
          attrs = Map.put(attrs, :instance_id, instance.id)
          Ash.Changeset.for_create(BackupSetting, :create, attrs, opts)

        setting ->
          Ash.Changeset.for_update(setting, :update, attrs, opts)
      end

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  # Field by field: an omitted (or nil) parameter keeps the stored value.
  # `prefix: nil` is the deliberate exception — it clears the prefix,
  # because "no prefix" is a setting, not a missing input.
  defp merge_attrs(nil, params) do
    params
    |> Map.take(@row_fields)
    |> Map.reject(fn {field, value} -> is_nil(value) and field != :prefix end)
  end

  defp merge_attrs(stored, params) do
    Enum.reduce(@row_fields, %{}, fn field, merged ->
      case Map.fetch(params, field) do
        {:ok, value} when not is_nil(value) -> Map.put(merged, field, value)
        {:ok, nil} when field == :prefix -> Map.put(merged, field, nil)
        _keep_stored -> Map.put(merged, field, Map.get(stored, field))
      end
    end)
  end

  # Never deployed: no namespace, so no Secret to write and no quota to
  # widen. Checked after the ownership read — a stranger learns nothing.
  defp kubeconfig(%{namespace: nil}), do: {:error, :not_deployed}
  defp kubeconfig(instance), do: InstanceK8s.kubeconfig_for(instance)

  # Get-or-create, never blind-apply: an existing Secret is the repo's
  # identity — its password survives every save or the snapshots do not.
  defp secret_data(kubeconfig, instance, changeset, params) do
    # A blank form field means "keep what's stored", not "set it empty".
    secret_input = blank_to_nil(Map.get(params, :secret_access_key))

    case Secret.get_data(kubeconfig, instance.namespace, @secret_name) do
      {:ok, existing} ->
        with {:ok, password} <- stored_password(existing),
             {:ok, secret_key} <- secret_key(existing, secret_input) do
          {:ok, data_for(changeset, password, secret_key)}
        end

      {:error, %Error{reason: :not_found}} ->
        fresh_secret_data(changeset, secret_input)

      {:error, error} ->
        {:error, error}
    end
  end

  # The password is the repo's identity (ADR-0037 §4). Missing from an
  # existing Secret means it was written out-of-band or truncated;
  # regenerating it would orphan every snapshot already in the bucket, so
  # a corrupt Secret fails loudly and rotates nothing.
  defp stored_password(existing) do
    case Map.get(existing, @password_key) do
      password when is_binary(password) and password != "" -> {:ok, password}
      _missing -> {:error, :secret_corrupt}
    end
  end

  # The form's key wins when it carries one, else the stored credential.
  defp secret_key(existing, nil) do
    case Map.get(existing, @secret_access_key_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _missing -> {:error, :secret_access_key_required}
    end
  end

  defp secret_key(_existing, secret_input), do: {:ok, secret_input}

  # First save: no stored credential to fall back on — the form must
  # supply the S3 secret, since the Job cannot authenticate without it.
  defp fresh_secret_data(_changeset, nil), do: {:error, :secret_access_key_required}

  defp fresh_secret_data(changeset, secret_key) do
    {:ok, data_for(changeset, generate_password(), secret_key)}
  end

  defp data_for(changeset, password, secret_key) do
    %{
      @repo_key => repo_url(changeset),
      @password_key => password,
      @access_key_id_key => Ash.Changeset.get_attribute(changeset, :access_key_id),
      @secret_access_key_key => secret_key
    }
  end

  # restic's S3 shape: "s3:" <> endpoint "/" bucket ["/" prefix]. The
  # endpoint cannot carry a path (the attribute's fence), so the only
  # normalization left is its legal trailing slash — drop it so the join
  # is exactly one separator and the bucket can never be doubled.
  defp repo_url(changeset) do
    endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)
    trimmed_endpoint = String.trim_trailing(endpoint, "/")
    bucket = Ash.Changeset.get_attribute(changeset, :bucket)
    base = trimmed_endpoint <> "/" <> bucket

    case Ash.Changeset.get_attribute(changeset, :prefix) do
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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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
  # The margin applies whenever a settings row exists (DeployInstance's
  # `backups_configured?`), and every save re-applies it: a disable is a
  # plain row update, so no path can narrow the quota while the row is
  # there and a later re-enable needs no quota write to start backing up.
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

  # The pre-built, validated changeset: the row is written once, after
  # the cluster state it records.
  defp write_row(%Ash.Changeset{action_type: :create} = changeset), do: Ash.create(changeset)
  defp write_row(%Ash.Changeset{action_type: :update} = changeset), do: Ash.update(changeset)
end

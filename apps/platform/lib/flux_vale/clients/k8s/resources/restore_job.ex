defmodule FluxVale.Clients.K8s.Resources.RestoreJob do
  @moduledoc """
  CRUD + status for the per-instance restic **restore** Job (#222,
  ADR-0037 §5).

  One Job, fixed name `backup-restore`, in the Instance's namespace: the
  same pinned stock image (`config :flux_vale, :backups`), the same
  `backup-config` Secret via `envFrom`, the same requests — but the PVC is
  mounted **read-write**, because this Job writes the snapshot back over
  the volume.

  ## Why a sibling of `BackupJob`, not an extension

  The two Jobs share everything *around* the container (apply/get/delete,
  the verdict-then-pod-message read, error translation) and nothing
  *inside* it: different name, different mount mode, different script,
  different deadline. Each `Clients.K8s.Resources.*` module is already a
  standalone client owning its own CRUD arms — that is the house shape,
  and the repetitive response arms are what `coveralls.json`'s
  `custom_stop_words` exists for. Parameterising one module over "which
  direction" would fork the spec type, the script accessor, and the
  deadline key inside every function, for a saving of about forty lines.

  ## Spec

      %{
        slug: "quiet-otter",       # Required: RESTIC_HOST pin
        mount_path: "/data",       # Required: the Instance's storage_mount_path
        snapshot_id: "6b757e02",   # Required: the snapshot to write back
        run_id: "0199c3…"          # Required: the BackupRun row this Job serves
      }

  ## Restoring in place

  `restic restore <id> --target <dir>` extracts the snapshot's **absolute**
  paths *under* `<dir>`: a snapshot of `/data` restored with
  `--target /data` lands in `/data/data`. Verified against the pinned
  `restic/restic:0.19.1` image. The script therefore uses restic's
  `<snapshot>:<subfolder>` form with the target set to the mount itself,
  which is the in-place shape ADR-0037 §5 means.

  `--delete` rides along: a restore should make the volume *be* the
  snapshot, not the snapshot plus whatever the app wrote after it — a
  half-merged volume is the inconsistent state restores exist to avoid.
  (With the `<snapshot>:<subfolder>` form restic deletes only within that
  subtree, so no `--include` is needed beside `--target`.)

  `--verify` also rides along, at the cost of a second read pass over the
  restored files. The trade is deliberate and one-directional: the restore
  is the moment the user's only good copy is written back, and a restore
  that silently lands corrupt data is worse than a slower one. Restores
  are owner-initiated and rare, and they run under their own
  `restore_timeout_seconds` (see below), so the extra pass fits.

  ## Why no init guard

  The backup script init-guards because a first run has no repo yet. A
  restore names a snapshot that already exists, so the repo must too:
  exit 10 (no repo) and 12 (wrong password) are real failures here, never
  an invitation to create one over the user's data.

  ## `activeDeadlineSeconds`

  `config :flux_vale, :backups, :restore_timeout_seconds`, not the backup
  Job's `:timeout_seconds`. The directions differ in cost: a backup
  uploads only the chunks that changed, while a restore downloads every
  chunk of the snapshot and then reads it back to verify. Reusing the
  backup's tighter deadline would kill a legitimate large restore, and
  widening the shared key would loosen the hang bound on the backup path
  too.

  ## The outcome channel

  Unchanged from `BackupJob`: the Job carries the aggregate verdict, the
  Pod's terminated container carries the script's one-line JSON in
  `terminationMessage` (ADR-0037 Am. 1). No pod logs are ever read —
  restic's stream carries the user's file paths.
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @name "backup-restore"
  @container "backup"
  @secret_name "backup-config"
  @pvc_name "app-data"
  @volume "storage"

  # The ownership link: a row's id on the fixed-name Job that serves it
  # (the sweep refuses to attribute an outcome to a row the Job's label
  # does not name).
  @run_label "fluxvale.io/backup-run"

  @typedoc "Restore Job specification"
  @type spec :: %{
          required(:slug) => String.t(),
          required(:mount_path) => String.t(),
          required(:snapshot_id) => String.t(),
          required(:run_id) => String.t()
        }

  @typedoc "The Job's verdict plus its termination message (see `BackupJob.outcome/0`)."
  @type outcome :: %{
          outcome: :running | :succeeded | :failed,
          message: String.t() | nil,
          exit_code: integer() | nil,
          reason: String.t() | nil,
          run_id: String.t() | nil
        }

  @doc "The Job's fixed name — one live restore Job per instance."
  @spec name() :: String.t()
  def name, do: @name

  @doc "Creates (server-side-applies) the restore Job."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created restore job: #{namespace}/#{@name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated restore job: #{namespace}/#{@name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets the restore Job."
  @spec get(Kubereq.Kubeconfig.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(kubeconfig, namespace) do
    req = create_req(kubeconfig)

    case Kubereq.get(req, namespace, @name) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Deletes the restore Job. Jobs are immutable — a previous restore's Job
  must go before the next one applies, so the caller tolerates `:not_found`.
  """
  @spec delete(Kubereq.Kubeconfig.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, @name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted restore job: #{namespace}/#{@name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("Restore job deletion initiated: #{namespace}/#{@name}")
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Reads the Job's outcome — the watch pass's input. Same two reads as
  `BackupJob.status/2`: the Job's verdict, then its pod's terminated
  container `message` once there is a verdict.
  """
  @spec status(Kubereq.Kubeconfig.t(), String.t()) :: {:ok, outcome()} | {:error, Error.t()}
  def status(kubeconfig, namespace) do
    with {:ok, job} <- get(kubeconfig, namespace) do
      job
      |> verdict()
      |> settle(kubeconfig, namespace, run_id(job), uid(job))
    end
  end

  @doc "The Job's own uid — the ownership key for its pods."
  @spec uid(map()) :: String.t() | nil
  def uid(job), do: get_in(job, ["metadata", "uid"])

  # The Job object carries no container statuses — that is the Pod's
  # (our own pod, matched by the label the Job's template sets).
  # The Job's pods — a POD-typed request (core v1), never the Job-typed
  # one above: a list against batch/v1 Jobs returns Job objects, which
  # carry no containerStatuses, and the outcome read would always be
  # nil — every successful restore recorded as failed. The composition
  # test pins the kind.
  @doc "Lists the Job's pods."
  @spec pods(Kubereq.Kubeconfig.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def pods(kubeconfig, namespace) do
    req =
      Kubereq.attach(Req.new(),
        kubeconfig: kubeconfig,
        api_version: "v1",
        kind: "Pod"
      )

    case Kubereq.list(req, namespace, label_selectors: [{"app.kubernetes.io/name", @name}]) do
      {:ok, %{status: 200, body: %{"items" => items}}} when is_list(items) ->
        {:ok, items}

      {:ok, %{status: 200, body: body}} ->
        {:error, Error.validation_error("Malformed PodList response: #{inspect(body)}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Builds the Job manifest.

  The container mounts the PVC **read-write** at the instance's
  `storage_mount_path` — this Job's whole purpose is writing back over it.
  """
  @spec build_manifest(String.t(), spec()) :: map()
  def build_manifest(namespace, spec) do
    config = Application.fetch_env!(:flux_vale, :backups)
    {cpu_request, cpu_limit} = cpu_strings(Decimal.new(config[:cpu_cores]))
    memory = config[:memory_mb]

    %{
      "apiVersion" => "batch/v1",
      "kind" => "Job",
      "metadata" => %{
        "name" => @name,
        "namespace" => namespace,
        "labels" => labels(spec)
      },
      "spec" => %{
        # One pod, one attempt — the platform owns retry, and a kube-level
        # retry would re-run a half-applied restore seconds later.
        "backoffLimit" => 0,
        "activeDeadlineSeconds" => config[:restore_timeout_seconds],
        "template" => %{
          "metadata" => %{"labels" => labels(spec)},
          "spec" => %{
            "restartPolicy" => "Never",
            "containers" => [container(spec, image(config), cpu_request, cpu_limit, memory)],
            "volumes" => [
              %{
                "name" => @volume,
                "persistentVolumeClaim" => %{"claimName" => @pvc_name}
              }
            ]
          }
        }
      }
    }
  end

  defp image(config), do: config[:image]

  # The run-id label rides both the Job and its pod template (the pod
  # list selects on the name label; the run label is the sweep's
  # ownership check — see the outcome type).
  defp labels(spec) do
    %{
      "app.kubernetes.io/managed-by" => "fluxvale",
      "app.kubernetes.io/name" => @name,
      @run_label => Map.get(spec, :run_id)
    }
  end

  defp container(spec, image, cpu_request, cpu_limit, memory) do
    %{
      "name" => @container,
      "image" => image,
      "command" => ["/bin/sh", "-c"],
      "args" => [script(spec)],
      "envFrom" => [%{"secretRef" => %{"name" => @secret_name}}],
      # Same grouping key as the backup Job: harmless for a pinned
      # snapshot id, and it keeps the pod spec uniform with its sibling.
      "env" => [%{"name" => "RESTIC_HOST", "value" => spec.slug}],
      "resources" => %{
        "requests" => %{"cpu" => cpu_request, "memory" => "#{memory}Mi"},
        "limits" => %{"cpu" => cpu_limit, "memory" => "#{memory * 2}Mi"}
      },
      "volumeMounts" => [
        %{
          "name" => @volume,
          "mountPath" => spec.mount_path,
          "readOnly" => false
        }
      ]
    }
  end

  # CPU as canonical quantity strings — the backup Job's shape.
  defp cpu_strings(cpu) do
    normalized = Decimal.normalize(cpu)

    limit =
      normalized
      |> Decimal.mult(2)
      |> Decimal.normalize()

    {Decimal.to_string(normalized), Decimal.to_string(limit)}
  end

  # One line of JSON on both paths — the platform's only outcome channel.
  @script ~S"""
  set -u -o pipefail

  mount="__MOUNT__"
  snapshot="__SNAPSHOT__"
  out=/tmp/restore.json
  err=/tmp/restore.err

  # The reason survives only here: last stderr line, one line, capped.
  # --json makes that line a restic JSON event, so its .message is the
  # human half; a non-JSON line is used as-is.
  last_error() {
    line=$(tail -n 1 "$err" 2>/dev/null)
    message=$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)
    printf '%s' "${message:-$line}" | cut -c 1-300
  }

  finish_failed() {
    printf 'restore failed: %s\n' "$1" >&2
    jq -cn --arg error "$1" '{error: $error}' > /dev/termination-log
    exit "${2:-1}"
  }

  # No init guard (see moduledoc): a restore names an existing snapshot, so
  # a missing repo or a wrong password is a failure, not a first run.
  #
  # <snapshot>:<mount> restores IN PLACE — a snapshot of /data handed to
  # --target /data without the subfolder form would land in /data/data.
  # --delete makes the volume match the snapshot instead of merging into
  # it; --verify reads the written files back (the deliberate second pass).
  restic restore "$snapshot:$mount" --target "$mount" --delete --verify --json >"$out" 2>"$err"
  status=$?
  [ "$status" -eq 0 ] || finish_failed "restic restore exited $status: $(last_error)" "$status"

  bytes_restored=$(tail -n 1 "$out" | jq -r '.bytes_restored // 0')

  jq -cn \
    --arg snapshot_id "$snapshot" \
    --argjson bytes_restored "$bytes_restored" \
    '{snapshot_id: $snapshot_id, bytes_restored: $bytes_restored}' \
    > /dev/termination-log
  """

  @doc """
  The Job's `sh -c` script, verbatim, with the instance's mount path and
  the snapshot id substituted.

  Read it top to bottom: restore in place, verify, then report. Every exit
  path writes the termination message first.
  """
  @spec script(spec()) :: String.t()
  def script(spec) do
    @script
    |> String.replace("__MOUNT__", spec.mount_path)
    |> String.replace("__SNAPSHOT__", spec.snapshot_id)
  end

  @doc """
  The Job's verdict without the pod read — `:running` while the
  controller has no answer yet.
  """
  @spec verdict(map()) :: :running | :succeeded | :failed
  def verdict(job) do
    cond do
      succeeded?(job) -> :succeeded
      failed?(job) -> :failed
      true -> :running
    end
  end

  defp succeeded?(job) do
    get_in(job, ["status", "succeeded"]) not in [nil, 0] or condition?(job, "Complete")
  end

  defp failed?(job) do
    get_in(job, ["status", "failed"]) not in [nil, 0] or condition?(job, "Failed")
  end

  # Only a settled Job pays for the second read.
  defp settle(:running, _kubeconfig, _namespace, _run_id, _uid) do
    {:ok, %{outcome: :running, message: nil, exit_code: nil, reason: nil, run_id: nil}}
  end

  # The pod read is ownership-scoped (the backup builder's identical
  # review fix): a leftover pod must never speak for this Job's run.
  defp settle(verdict, kubeconfig, namespace, run_id, uid) do
    case pods(kubeconfig, namespace) do
      {:ok, pod_list} ->
        {:ok, outcome(verdict, terminated_state(owned_pods(pod_list, uid)), run_id)}

      {:error, _error} = error ->
        error
    end
  end

  # nil uid (a hand-built fixture): keep the name-label semantics.
  defp owned_pods(pod_list, nil), do: pod_list

  defp owned_pods(pod_list, uid) do
    Enum.filter(pod_list, &owned_by?(&1, uid))
  end

  defp owned_by?(pod, uid) do
    pod
    |> get_in(["metadata", "ownerReferences"])
    |> List.wrap()
    |> Enum.any?(fn ref -> ref["uid"] == uid and ref["kind"] == "Job" end)
  end

  defp outcome(:succeeded, terminated, run_id) do
    %{
      outcome: :succeeded,
      message: message(terminated),
      exit_code: exit_code(terminated),
      reason: reason(terminated, "Completed"),
      run_id: run_id
    }
  end

  defp outcome(:failed, terminated, run_id) do
    %{
      outcome: :failed,
      message: message(terminated),
      exit_code: exit_code(terminated),
      reason: reason(terminated, "BackoffLimitExceeded"),
      run_id: run_id
    }
  end

  defp message(terminated), do: terminated && terminated["message"]
  defp exit_code(terminated), do: terminated && terminated["exitCode"]
  defp reason(terminated, fallback), do: (terminated && terminated["reason"]) || fallback

  # The run-id label — the ownership link between a row and the
  # fixed-name Job that serves it.
  @doc "The `fluxvale.io/backup-run` label off a Job object, nil if absent."
  @spec run_id(map()) :: String.t() | nil
  def run_id(job), do: get_in(job, ["metadata", "labels", @run_label])

  defp terminated_state(pod_list) do
    pod_list
    |> Enum.flat_map(fn pod -> get_in(pod, ["status", "containerStatuses"]) || [] end)
    |> Enum.find_value(fn status ->
      case get_in(status, ["state", "terminated"]) do
        nil -> nil
        terminated -> terminated
      end
    end)
  end

  defp condition?(job, type) do
    job
    |> get_in(["status", "conditions"])
    |> List.wrap()
    |> Enum.any?(fn condition -> condition["type"] == type and condition["status"] == "True" end)
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "batch/v1", kind: "Job")
  end
end

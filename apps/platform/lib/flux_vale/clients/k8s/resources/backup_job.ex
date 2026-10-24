defmodule FluxVale.Clients.K8s.Resources.BackupJob do
  @moduledoc """
  CRUD + status for the per-instance restic backup Job (#222, ADR-0037 §3).

  One Job, fixed name `backup-run`, in the Instance's namespace: the
  pinned stock restic image (`config :flux_vale, :backups`) reads the
  instance's PVC **read-only** and writes snapshots to the user's
  S3-compatible bucket. Everything secret rides the `backup-config`
  Secret via `envFrom` — nothing on the command line, nothing in the pod
  spec.

  ## Spec

      %{
        slug: "quiet-otter",       # Required: RESTIC_HOST pin
        mount_path: "/data",       # Required: the Instance's storage_mount_path
        keep_last: 7               # Required: retention_keep
      }

  ## Why `backoffLimit: 0` and `restartPolicy: Never`

  The platform owns retry: the next scheduled window, or the owner's
  manual retry, both run the same operation. A kube-level retry inside
  the same Job would re-run restic against the same repo seconds later —
  restic's repo locks make blind retries counterproductive (the second
  attempt can fail on the first's stale lock while both hold the same
  PVC), and the platform would show one run instead of the two attempts
  that actually happened. So: one pod, one attempt, one row.

  ## Why the hostname is pinned

  restic groups snapshots by hostname for parent lookup and retention.
  Pod names are random, so an unpinned host would fragment the repo into
  one group per run and break both dedup and `--keep-last`. The Job sets
  `RESTIC_HOST` to the Instance slug.

  ## The outcome channel

  The script writes one line of JSON to `/dev/termination-log` on **both**
  paths. `status/2` combines two reads, because Kubernetes splits the
  facts: the **Job** carries the aggregate verdict (`status.succeeded` /
  `status.failed` / conditions) and the **Pod** carries the terminated
  container's `terminationMessage` — `JobStatus` has no
  `containerStatuses` field; that is a Pod field, and ADR-0037 §3's path
  is the Pod's. No pod logs are ever read: restic's streaming output
  carries the user's file paths, so the script discards it.

  ## `activeDeadlineSeconds`

  A run that hangs (unreachable endpoint, stalled upload) would otherwise
  hold the instance's single run slot forever. The deadline is the
  platform's own bound (`config :flux_vale, :backups, :timeout_seconds`)
  and turns a hang into a k8s Job failure the watch pass finalizes.

  Note: the Job carries **no** `ttlSecondsAfterFinished` — the watch pass
  needs the object to read the outcome; the next run deletes it.
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @name "backup-run"
  @container "backup"
  @secret_name "backup-config"
  @pvc_name "app-data"
  @volume "storage"

  # The ownership link: a row's id on the fixed-name Job that serves it
  # (the sweep refuses to attribute an outcome to a row the Job's label
  # does not name).
  @run_label "fluxvale.io/backup-run"

  # restic's own exit code for "repository does not exist" (>= 0.17);
  # the script's init branch keys on it.
  @repo_missing_exit 10

  @typedoc "Backup Job specification"
  @type spec :: %{
          required(:slug) => String.t(),
          required(:mount_path) => String.t(),
          required(:keep_last) => integer(),
          required(:run_id) => String.t()
        }

  @typedoc """
  What the Job says about itself:

  - `:running` — no verdict yet (the next sweep looks again)
  - `:succeeded` — the Job completed; `message` is the termination log
  - `:failed` — the Job failed, or its pod failed to start

  `message` is the termination message (our one-line JSON), `nil` when
  the container never reported one. `run_id` is the Job's
  `fluxvale.io/backup-run` label — the sweep's ownership check: the
  fixed-name Job outlives its run (immutable objects), so the watch
  pass must not attribute one run's outcome to another run's row.
  """
  @type outcome :: %{
          outcome: :running | :succeeded | :failed,
          message: String.t() | nil,
          exit_code: integer() | nil,
          reason: String.t() | nil,
          run_id: String.t() | nil
        }

  @doc "The Job's fixed name — one live backup Job per instance."
  @spec name() :: String.t()
  def name, do: @name

  @doc "Creates (server-side-applies) the backup Job."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created backup job: #{namespace}/#{@name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated backup job: #{namespace}/#{@name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets the backup Job."
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
  Deletes the backup Job. Jobs are immutable — a previous run's Job must
  go before the next one applies, so the caller tolerates `:not_found`.
  """
  @spec delete(Kubereq.Kubeconfig.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, @name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted backup job: #{namespace}/#{@name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("Backup job deletion initiated: #{namespace}/#{@name}")
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Reads the Job's outcome — the watch pass's input.

  Two reads: the Job's aggregate verdict, then (only once the Job has a
  verdict) its pod's terminated-container `message`, which is where the
  script's one-line JSON lands. A pod that failed to start (image pull,
  quota) has no message at all; the Job condition carries the reason.
  """
  @spec status(Kubereq.Kubeconfig.t(), String.t()) :: {:ok, outcome()} | {:error, Error.t()}
  def status(kubeconfig, namespace) do
    with {:ok, job} <- get(kubeconfig, namespace) do
      job
      |> verdict()
      |> settle(kubeconfig, namespace, run_id(job))
    end
  end

  # The Job object carries no container statuses — that is the Pod's
  # (our own pod, matched by the label the Job's template sets).
  # The Job's pods — a POD-typed request (core v1), never the Job-typed
  # one above: a list against batch/v1 Jobs returns Job objects, which
  # carry no containerStatuses, and the outcome read would always be
  # nil — every successful backup recorded as failed. Found in review;
  # the composition test pins the kind.
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

  The container mounts the PVC read-only at the instance's
  `storage_mount_path`: the backup set is the whole volume, and a
  read-write mount would let restic's cache or a crash scribble on the
  user's data.
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
        # One pod, one attempt (see moduledoc).
        "backoffLimit" => 0,
        "activeDeadlineSeconds" => config[:timeout_seconds],
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
      # The repo's grouping key — see moduledoc. restic reads RESTIC_HOST
      # (doc/075_scripting.rst); ADR-0037 §3's "RESTIC_HOSTNAME" names the
      # concept, not a variable restic supports.
      "env" => [%{"name" => "RESTIC_HOST", "value" => spec.slug}],
      "resources" => %{
        "requests" => %{"cpu" => cpu_request, "memory" => "#{memory}Mi"},
        "limits" => %{"cpu" => cpu_limit, "memory" => "#{memory * 2}Mi"}
      },
      "volumeMounts" => [
        %{
          "name" => @volume,
          "mountPath" => spec.mount_path,
          "readOnly" => true
        }
      ]
    }
  end

  # CPU as canonical quantity strings (#190's helper shape): requests at
  # the config value, limits at 2x, no float rounding.
  defp cpu_strings(cpu) do
    normalized = Decimal.normalize(cpu)

    limit =
      normalized
      |> Decimal.mult(2)
      |> Decimal.normalize()

    {Decimal.to_string(normalized), Decimal.to_string(limit)}
  end

  # One line of JSON on both paths — the platform's only outcome channel.
  # Errors are restic's exit code plus its last stderr line, capped: the
  # Secret's values never reach this string (restic does not echo them).
  @script ~S"""
  set -u -o pipefail

  mount="__MOUNT__"
  keep_last="__KEEP_LAST__"
  out=/tmp/backup.jsonl
  err=/tmp/backup.err

  # The reason survives only here: last stderr line, one line, capped.
  last_error() {
    tail -n 1 "$err" 2>/dev/null | cut -c 1-300
  }

  finish_failed() {
    printf 'backup failed: %s\n' "$1" >&2
    jq -cn --arg error "$1" '{error: $error}' > /dev/termination-log
    exit "${2:-1}"
  }

  # restic never auto-inits an S3 repo: exit 10 is "repository does not
  # exist" (restic >= 0.17). Anything else is a real failure (wrong
  # password, bad credentials, unreachable endpoint) — do not init over it.
  restic cat config >/dev/null 2>"$err"
  status=$?
  if [ "$status" -eq __REPO_MISSING_EXIT__ ]; then
    restic init >/dev/null 2>"$err" || finish_failed "restic init: $(last_error)"
  elif [ "$status" -ne 0 ]; then
    finish_failed "restic cat config exited $status: $(last_error)"
  fi

  # --json yields the summary event; the stream stays off the pod log
  # (nothing reads logs, and status lines carry the user's paths).
  restic backup --json --host "$RESTIC_HOST" "$mount" >"$out" 2>"$err"
  status=$?
  # restic exit 3 is "some source data unreadable" — the snapshot is
  # incomplete, so the run fails and the previous snapshot stays the
  # restore fallback (never report a partial backup as a good one).
  [ "$status" -eq 0 ] || finish_failed "restic backup exited $status: $(last_error)" "$status"

  # --host scopes retention to this instance's snapshots even if the
  # repo is ever shared; a repo that cannot prune is unhealthy, so the
  # run fails (ADR-0037 §3).
  restic forget --keep-last "$keep_last" --host "$RESTIC_HOST" --prune >/dev/null 2>"$err"
  status=$?
  [ "$status" -eq 0 ] || finish_failed "restic forget exited $status: $(last_error)"

  # restic 0.19's summary event carries snapshot_id, total_bytes_processed
  # and data_added_packed; the lookup is the fallback for a build that
  # omits the id. --path scopes it to this run's backup set (--latest
  # groups per host+path), newest first. An EMPTY summary (restic
  # printed nothing, or the last line was not the event) must not reach
  # the --argjson below: jq -r on empty input yields "" (exit 0), and
  # --argjson "" is a parse error that would mask a possibly-good backup
  # as a container error 2 — substitute {} so the byte fields default
  # to 0 and the snapshot lookup does its job.
  summary=$(tail -n 1 "$out")
  [ -n "$summary" ] || summary='{}'
  snapshot_id=$(printf '%s' "$summary" | jq -r '.snapshot_id // empty')

  if [ -z "$snapshot_id" ]; then
    snapshot_id=$(
      restic snapshots --json --path "$mount" --latest 1 2>/dev/null |
        jq -r 'sort_by(.time) | last | .id // empty'
    )
  fi

  # A success with no snapshot id is not a success: the panel would show a
  # green run with nothing to restore.
  [ -n "$snapshot_id" ] || finish_failed "backup succeeded but reported no snapshot id"

  bytes_processed=$(printf '%s' "$summary" | jq -r '.total_bytes_processed // 0')
  bytes_added=$(printf '%s' "$summary" | jq -r '.data_added_packed // 0')

  jq -cn \
    --arg snapshot_id "$snapshot_id" \
    --argjson bytes_processed "$bytes_processed" \
    --argjson bytes_added "$bytes_added" \
    '{snapshot_id: $snapshot_id, bytes_processed: $bytes_processed, bytes_added: $bytes_added}' \
    > /dev/termination-log
  """

  @doc """
  The Job's `sh -c` script, verbatim, with the instance's mount path and
  retention substituted.

  Read it top to bottom: verify the repo (init once), back up, prune,
  then report. Every exit path writes the termination message first.
  """
  @spec script(spec()) :: String.t()
  def script(spec) do
    @script
    |> String.replace("__MOUNT__", spec.mount_path)
    |> String.replace("__KEEP_LAST__", Integer.to_string(spec.keep_last))
    |> String.replace("__REPO_MISSING_EXIT__", Integer.to_string(@repo_missing_exit))
  end

  # The Job's verdict alone. `status.succeeded`/`status.failed` are the
  # aggregate counters the controller maintains; the terminal conditions
  # cover the "Reached max backoff" shape, where failed pods leave the
  # counter but no termination message exists.
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

  # The run-id label — the ownership link between a row and the
  # fixed-name Job that serves it.
  @doc "The `fluxvale.io/backup-run` label off a Job object, nil if absent."
  @spec run_id(map()) :: String.t() | nil
  def run_id(job), do: get_in(job, ["metadata", "labels", @run_label])

  defp succeeded?(job) do
    get_in(job, ["status", "succeeded"]) not in [nil, 0] or condition?(job, "Complete")
  end

  defp failed?(job) do
    get_in(job, ["status", "failed"]) not in [nil, 0] or condition?(job, "Failed")
  end

  # Only a settled Job pays for the second read: the pod's terminated
  # container carries the termination log; a still-running Job's outcome
  # is the next sweep's business.
  defp settle(:running, _kubeconfig, _namespace, _run_id) do
    {:ok, %{outcome: :running, message: nil, exit_code: nil, reason: nil, run_id: nil}}
  end

  defp settle(verdict, kubeconfig, namespace, run_id) do
    case pods(kubeconfig, namespace) do
      {:ok, pod_list} -> {:ok, outcome(verdict, terminated_state(pod_list), run_id)}
      {:error, _error} = error -> error
    end
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

  # The pod's `status.containerStatuses[]` — where Kubernetes puts the
  # terminated container's state, and where the termination log lands as
  # `state.terminated.message` (the platform's only outcome channel).
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

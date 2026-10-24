defmodule FluxVale.Clients.K8s.Resources.BackupJobTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob

  @spec_slug "quiet-otter"

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  defp spec(overrides \\ %{}) do
    Map.merge(%{slug: @spec_slug, mount_path: "/kavita/config", keep_last: 7}, overrides)
  end

  defp container(manifest) do
    containers = get_in(manifest, ["spec", "template", "spec", "containers"])
    hd(containers)
  end

  describe "build_manifest/2 — shape" do
    test "a batch/v1 Job named backup-run in the instance namespace" do
      manifest = BackupJob.build_manifest("fluxvale-app-abc", spec())

      assert manifest["apiVersion"] == "batch/v1"
      assert manifest["kind"] == "Job"
      assert manifest["metadata"]["name"] == "backup-run"
      assert manifest["metadata"]["namespace"] == "fluxvale-app-abc"
      assert BackupJob.name() == "backup-run"
    end

    test "labels follow the builders' convention on the Job and its pod template" do
      manifest = BackupJob.build_manifest("ns", spec())
      expected = %{"app.kubernetes.io/managed-by" => "fluxvale"}

      assert Map.take(manifest["metadata"]["labels"], ["app.kubernetes.io/managed-by"]) ==
               expected

      assert Map.take(manifest["spec"]["template"]["metadata"]["labels"], [
               "app.kubernetes.io/managed-by"
             ]) == expected

      # The pod's label is also how status/2 finds its own pod.
      assert manifest["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] ==
               "backup-run"
    end

    test "one pod, one attempt: backoffLimit 0 and restartPolicy Never" do
      spec_map = BackupJob.build_manifest("ns", spec())["spec"]

      # The platform owns retry (next window / manual retry) and restic's
      # repo locks make blind kube-level retries counterproductive.
      assert spec_map["backoffLimit"] == 0
      assert spec_map["template"]["spec"]["restartPolicy"] == "Never"
    end

    test "the deadline bounds a hung run" do
      config = Application.fetch_env!(:flux_vale, :backups)
      manifest = BackupJob.build_manifest("ns", spec())

      assert manifest["spec"]["activeDeadlineSeconds"] == config[:timeout_seconds]
    end
  end

  describe "build_manifest/2 — the container" do
    test "pins RESTIC_HOST to the instance slug" do
      manifest = BackupJob.build_manifest("ns", spec())
      env = container(manifest)["env"]

      assert env == [%{"name" => "RESTIC_HOST", "value" => @spec_slug}]
    end

    test "consumes the backup-config Secret via envFrom — no secret in the spec" do
      manifest = BackupJob.build_manifest("ns", spec())
      container = container(manifest)

      assert container["envFrom"] == [%{"secretRef" => %{"name" => "backup-config"}}]

      # Nothing secret-shaped in the pod spec: the values are the Secret's.
      rendered = inspect(container["args"])
      refute rendered =~ "RESTIC_PASSWORD"
      refute rendered =~ "AWS_SECRET_ACCESS_KEY"
    end

    test "mounts the app-data PVC read-only at the instance's storage_mount_path" do
      manifest = BackupJob.build_manifest("ns", spec())
      container = container(manifest)

      assert container["volumeMounts"] == [
               %{"name" => "storage", "mountPath" => "/kavita/config", "readOnly" => true}
             ]

      assert manifest["spec"]["template"]["spec"]["volumes"] == [
               %{
                 "name" => "storage",
                 "persistentVolumeClaim" => %{"claimName" => "app-data"}
               }
             ]
    end

    test "a different mount path follows the instance, not a constant" do
      manifest = BackupJob.build_manifest("ns", spec(%{mount_path: "/data"}))

      assert [%{"mountPath" => "/data", "readOnly" => true}] = container(manifest)["volumeMounts"]
    end

    test "image and resources come from the :backups config (limits = 2x requests)" do
      config = Application.fetch_env!(:flux_vale, :backups)
      manifest = BackupJob.build_manifest("ns", spec())
      container = container(manifest)

      assert container["image"] == config[:image]
      assert container["image"] == "restic/restic:0.19.1"

      assert container["resources"] == %{
               "requests" => %{"cpu" => "0.1", "memory" => "128Mi"},
               "limits" => %{"cpu" => "0.2", "memory" => "256Mi"}
             }
    end
  end

  describe "script/1 — the heart" do
    test "fails the run on any pipeline stage, not just the last" do
      script = BackupJob.script(spec())

      assert script =~ "set -u -o pipefail"
    end

    test "writes a one-line JSON termination message on BOTH paths" do
      script = BackupJob.script(spec())

      # Failure: the helper owns the write, the only exit path on errors.
      assert script =~ "jq -cn --arg error \"$1\" '{error: $error}' > /dev/termination-log"
      # Success: snapshot id + both byte counts.
      assert script =~ "> /dev/termination-log"
      assert script =~ "snapshot_id: $snapshot_id"
      assert script =~ "bytes_processed: $bytes_processed"
      assert script =~ "bytes_added: $bytes_added"
    end

    test "initializes a fresh repo, and only on restic's missing-repo exit code" do
      script = BackupJob.script(spec())

      # restic does NOT auto-init an S3 repo: cat config's exit 10 is the
      # only init trigger, anything else is a real failure.
      assert script =~ "restic cat config"
      assert script =~ ~s(if [ "$status" -eq 10 ]; then)
      assert script =~ "restic init"
      assert script =~ ~s(elif [ "$status" -ne 0 ]; then)
    end

    test "backs up the mount, then retains with the row's retention" do
      keep = spec(%{keep_last: 14})
      script = BackupJob.script(keep)

      assert script =~ ~s(restic backup --json --host "$RESTIC_HOST" "$mount")
      assert script =~ ~s(keep_last="14")
      assert script =~ ~s(restic forget --keep-last "$keep_last" --host "$RESTIC_HOST" --prune)
    end

    test "a non-zero backup or forget exit fails the run" do
      script = BackupJob.script(spec())

      assert script =~ ~s([ "$status" -eq 0 ] || finish_failed "restic backup exited $status)
      assert script =~ ~s([ "$status" -eq 0 ] || finish_failed "restic forget exited $status)
    end

    test "the error string is restic's last stderr line, capped, one line" do
      script = BackupJob.script(spec())

      assert script =~ ~s(tail -n 1 "$err")
      assert script =~ "cut -c 1-300"
      # Nothing from the environment is echoed into the message.
      refute script =~ "$RESTIC_PASSWORD"
      refute script =~ "$AWS_SECRET_ACCESS_KEY"
    end

    test "the restic output stream never reaches the pod log" do
      script = BackupJob.script(spec())

      # --json goes to a file, not stdout: status lines carry user paths.
      assert script =~ ~s(>"$out")
      refute script =~ ~s(restic backup --json --host "$RESTIC_HOST" "$mount" 2>&1)
    end

    test "the mount path is substituted, never left as a template token" do
      mount = spec(%{mount_path: "/forgejo/data"})
      script = BackupJob.script(mount)

      assert script =~ ~s(mount="/forgejo/data")
      refute script =~ "__MOUNT__"
      refute script =~ "__KEEP_LAST__"
      refute script =~ "__REPO_MISSING_EXIT__"
    end

    test "the snapshot-id fallback is scoped to this backup set, and a missing id fails" do
      script = BackupJob.script(spec())

      # --latest groups per host+path, so the lookup names the path; the
      # sort is because restic's array order is not a contract.
      assert script =~ ~s(restic snapshots --json --path "$mount" --latest 1)
      assert script =~ "sort_by(.time) | last"

      # A green run with nothing to restore is the one outcome the panel
      # must never show.
      assert script =~ "backup succeeded but reported no snapshot id"
    end
  end

  describe "create/3" do
    test "applies the manifest with the fluxvale field manager" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert manifest["kind"] == "Job"
        assert field_manager == "fluxvale"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "Job"}} = BackupJob.create(%{}, "ns", spec())
    end

    test "a non-2xx response is an error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 422, body: %{"message" => "immutable"}}}
      end)

      assert {:error, %Error{reason: :api_error}} = BackupJob.create(%{}, "ns", spec())
    end

    test "a transport failure is an error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:error, :timeout} end)

      assert {:error, %Error{reason: :connection_error}} = BackupJob.create(%{}, "ns", spec())
    end
  end

  describe "get/2" do
    test "returns the Job" do
      expect(Kubereq, :get, fn _req, "ns", "backup-run" ->
        {:ok, %{status: 200, body: %{"a" => 1}}}
      end)

      assert {:ok, %{"a" => 1}} = BackupJob.get(%{}, "ns")
    end

    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = BackupJob.get(%{}, "ns")
    end

    test "other statuses and transport errors are errors" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 500, body: %{}}} end)

      assert {:error, %Error{reason: :api_error}} = BackupJob.get(%{}, "ns")

      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :closed} end)

      assert {:error, %Error{reason: :connection_error}} = BackupJob.get(%{}, "ns")
    end
  end

  describe "delete/2" do
    test "200 and 202 both delete" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200}} end)
      assert :ok = BackupJob.delete(%{}, "ns")

      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 202}} end)
      assert :ok = BackupJob.delete(%{}, "ns")
    end

    test "404 is :not_found — the caller tolerates it" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = BackupJob.delete(%{}, "ns")
    end

    test "other statuses and transport errors are errors" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 500, body: %{}}} end)

      assert {:error, %Error{reason: :api_error}} = BackupJob.delete(%{}, "ns")

      expect(Kubereq, :delete, fn _req, _ns, _name -> {:error, :timeout} end)

      assert {:error, %Error{reason: :connection_error}} = BackupJob.delete(%{}, "ns")
    end
  end

  describe "pods/2" do
    test "lists the Job's pods by the template's name label" do
      expect(Kubereq, :list, fn _req, "ns", opts ->
        assert opts[:label_selectors] == [{"app.kubernetes.io/name", "backup-run"}]
        {:ok, %{status: 200, body: %{"items" => [%{"metadata" => %{"name" => "backup-run-x"}}]}}}
      end)

      assert {:ok, [%{"metadata" => %{"name" => "backup-run-x"}}]} = BackupJob.pods(%{}, "ns")
    end

    test "a malformed list body is a validation error" do
      expect(Kubereq, :list, fn _req, _ns, _opts ->
        {:ok, %{status: 200, body: %{"items" => "nope"}}}
      end)

      assert {:error, %Error{reason: :validation_error}} = BackupJob.pods(%{}, "ns")
    end

    test "non-2xx and transport errors propagate" do
      expect(Kubereq, :list, fn _req, _ns, _opts -> {:ok, %{status: 500, body: %{}}} end)

      assert {:error, %Error{reason: :api_error}} = BackupJob.pods(%{}, "ns")

      expect(Kubereq, :list, fn _req, _ns, _opts -> {:error, :timeout} end)

      assert {:error, %Error{reason: :connection_error}} = BackupJob.pods(%{}, "ns")
    end
  end

  describe "status/2 — the outcome" do
    defp stub_job(job) do
      stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: job}} end)
    end

    defp stub_pods(pods) do
      stub(Kubereq, :list, fn _req, _ns, _opts ->
        {:ok, %{status: 200, body: %{"items" => pods}}}
      end)
    end

    defp pod_with_message(message) do
      %{
        "status" => %{
          "containerStatuses" => [
            %{"state" => %{"terminated" => %{"exitCode" => 0, "message" => message}}}
          ]
        }
      }
    end

    test "a Job with no verdict is :running — and costs no pod read" do
      stub_job(%{"status" => %{}})
      reject(Kubereq, :list, 3)

      assert {:ok, %{outcome: :running, message: nil}} = BackupJob.status(%{}, "ns")
    end

    test "a completed Job carries its pod's termination message" do
      message = ~s({"snapshot_id":"abc","bytes_processed":10,"bytes_added":5})
      stub_job(%{"status" => %{"succeeded" => 1}})
      stub_pods([pod_with_message(message)])

      assert {:ok, outcome} = BackupJob.status(%{}, "ns")
      assert outcome.outcome == :succeeded
      assert outcome.message == message
      assert outcome.exit_code == 0
      assert outcome.reason == "Completed"
    end

    test "a failed pod is :failed with its exit code and message" do
      message = ~s({"error":"restic backup exited 1: Fatal: boom"})

      stub_job(%{"status" => %{"failed" => 1}})

      stub_pods([
        %{
          "status" => %{
            "containerStatuses" => [
              %{
                "state" => %{
                  "terminated" => %{"exitCode" => 1, "reason" => "Error", "message" => message}
                }
              }
            ]
          }
        }
      ])

      assert {:ok, outcome} = BackupJob.status(%{}, "ns")
      assert outcome.outcome == :failed
      assert outcome.exit_code == 1
      assert outcome.reason == "Error"
      assert outcome.message == message
    end

    test "a failed Job whose pod never started reports the failure without a message" do
      # Image pull / quota rejection: no terminated container at all.
      stub_job(%{
        "status" => %{
          "failed" => 1,
          "conditions" => [%{"type" => "Failed", "status" => "True", "reason" => "BackoffLimit"}]
        }
      })

      stub_pods([])

      assert {:ok, outcome} = BackupJob.status(%{}, "ns")
      assert outcome.outcome == :failed
      assert outcome.message == nil
      assert outcome.exit_code == nil
      assert outcome.reason == "BackoffLimitExceeded"
    end

    test "a pod whose container has no terminated state yet is skipped" do
      # Between scheduling and exit the pod exists with no terminated
      # container (or a running one) — the next sweep reads it again.
      stub_job(%{"status" => %{"succeeded" => 1}})

      stub_pods([
        %{"status" => %{"containerStatuses" => [%{"state" => %{"running" => %{}}}]}},
        %{"status" => %{}}
      ])

      assert {:ok, outcome} = BackupJob.status(%{}, "ns")
      assert outcome.outcome == :succeeded
      assert outcome.message == nil
      assert outcome.exit_code == nil
    end

    test "the Complete condition counts as success when the counters are absent" do
      stub_job(%{"status" => %{"conditions" => [%{"type" => "Complete", "status" => "True"}]}})
      stub_pods([pod_with_message(~s({"snapshot_id":"abc"}))])

      assert {:ok, %{outcome: :succeeded, message: msg}} = BackupJob.status(%{}, "ns")
      assert msg =~ "abc"
    end

    test "a pod read failure propagates (the sweep retries)" do
      stub_job(%{"status" => %{"succeeded" => 1}})

      stub(Kubereq, :list, fn _req, _ns, _opts ->
        {:error, :econnrefused}
      end)

      assert {:error, %Error{reason: :connection_error}} = BackupJob.status(%{}, "ns")
    end

    test "a Job read failure propagates" do
      stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = BackupJob.status(%{}, "ns")
    end
  end

  describe "verdict/1" do
    test "zero counters are not a verdict" do
      assert BackupJob.verdict(%{"status" => %{"succeeded" => 0, "failed" => 0}}) == :running
      assert BackupJob.verdict(%{}) == :running
    end

    test "non-zero counters are" do
      assert BackupJob.verdict(%{"status" => %{"succeeded" => 1}}) == :succeeded
      assert BackupJob.verdict(%{"status" => %{"failed" => 1}}) == :failed
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "batch/v1"
      assert opts[:kind] == "Job"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)
    BackupJob.get(%{}, "ns")
  end
end

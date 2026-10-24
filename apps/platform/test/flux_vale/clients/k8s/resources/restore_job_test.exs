defmodule FluxVale.Clients.K8s.Resources.RestoreJobTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.RestoreJob

  @spec_slug "quiet-otter"
  @snapshot "6b757e02e6a7"
  @run_id "0199c3f4-0000-7000-8000-000000000222"

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{slug: @spec_slug, mount_path: "/kavita/config", snapshot_id: @snapshot, run_id: @run_id},
      overrides
    )
  end

  defp container(manifest) do
    containers = get_in(manifest, ["spec", "template", "spec", "containers"])
    hd(containers)
  end

  describe "build_manifest/2 — shape" do
    test "a batch/v1 Job named backup-restore in the instance namespace" do
      manifest = RestoreJob.build_manifest("fluxvale-app-abc", spec())

      assert manifest["apiVersion"] == "batch/v1"
      assert manifest["kind"] == "Job"
      assert manifest["metadata"]["name"] == "backup-restore"
      assert manifest["metadata"]["namespace"] == "fluxvale-app-abc"
      assert RestoreJob.name() == "backup-restore"
    end

    test "its name is its own — the backup Job's object is never collided with" do
      # Both live in the same namespace, and Jobs are immutable: a shared
      # name would make one direction delete the other's Job mid-run.
      refute RestoreJob.name() == BackupJob.name()
    end

    test "one pod, one attempt: backoffLimit 0 and restartPolicy Never" do
      spec_map = RestoreJob.build_manifest("ns", spec())["spec"]

      assert spec_map["backoffLimit"] == 0
      assert spec_map["template"]["spec"]["restartPolicy"] == "Never"
    end

    test "the deadline is the restore's own config key, not the backup's" do
      config = Application.fetch_env!(:flux_vale, :backups)
      manifest = RestoreJob.build_manifest("ns", spec())

      assert manifest["spec"]["activeDeadlineSeconds"] == config[:restore_timeout_seconds]
      # A restore moves every chunk in both directions; reusing the
      # backup's bound would kill a legitimate large restore.
      assert config[:restore_timeout_seconds] > config[:timeout_seconds]
    end

    test "pod labels carry the name the status read selects its pod by" do
      manifest = RestoreJob.build_manifest("ns", spec())

      assert manifest["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] ==
               "backup-restore"

      assert manifest["metadata"]["labels"]["app.kubernetes.io/managed-by"] == "fluxvale"
    end

    # The ownership link (the backup Job's shape): the fixed-name Job
    # outlives its run, so the sweep must be able to tell whose verdict it
    # is reading. The run-id label rides the Job and the pod template.
    test "the run-id label rides the Job and its pod template" do
      manifest = RestoreJob.build_manifest("ns", spec(%{run_id: "run-42"}))

      assert manifest["metadata"]["labels"]["fluxvale.io/backup-run"] == "run-42"

      assert manifest["spec"]["template"]["metadata"]["labels"]["fluxvale.io/backup-run"] ==
               "run-42"
    end
  end

  describe "build_manifest/2 — the container" do
    test "mounts the PVC READ-WRITE — this Job writes the volume back" do
      manifest = RestoreJob.build_manifest("ns", spec())

      assert container(manifest)["volumeMounts"] == [
               %{"name" => "storage", "mountPath" => "/kavita/config", "readOnly" => false}
             ]

      assert manifest["spec"]["template"]["spec"]["volumes"] == [
               %{
                 "name" => "storage",
                 "persistentVolumeClaim" => %{"claimName" => "app-data"}
               }
             ]
    end

    test "pins RESTIC_HOST to the instance slug" do
      manifest = RestoreJob.build_manifest("ns", spec())

      assert container(manifest)["env"] == [%{"name" => "RESTIC_HOST", "value" => @spec_slug}]
    end

    test "consumes the backup-config Secret via envFrom — no secret in the spec" do
      manifest = RestoreJob.build_manifest("ns", spec())
      built = container(manifest)

      assert built["envFrom"] == [%{"secretRef" => %{"name" => "backup-config"}}]

      rendered = inspect(built["args"])
      refute rendered =~ "RESTIC_PASSWORD"
      refute rendered =~ "AWS_SECRET_ACCESS_KEY"
    end

    test "image and resources are the backup Job's — one config block" do
      config = Application.fetch_env!(:flux_vale, :backups)
      manifest = RestoreJob.build_manifest("ns", spec())
      built = container(manifest)

      assert built["image"] == config[:image]
      assert built["image"] == "restic/restic:0.19.1"

      assert built["resources"] == %{
               "requests" => %{"cpu" => "0.1", "memory" => "128Mi"},
               "limits" => %{"cpu" => "0.2", "memory" => "256Mi"}
             }
    end
  end

  # The script's assertions below are the semantics verified against the
  # pinned restic/restic:0.19.1 image, not a reading of its docs: the
  # in-place form (a plain --target <mount> writes to <mount><mount>),
  # the exit codes, and which stream carries the summary.
  describe "script/1 — the heart" do
    test "fails the run on any pipeline stage, not just the last" do
      assert RestoreJob.script(spec()) =~ "set -u -o pipefail"
    end

    test "restores IN PLACE via the <snapshot>:<subfolder> form" do
      script = RestoreJob.script(spec())

      # Verified: `restic restore <id> --target /data` on a snapshot of
      # /data lands in /data/data. The subfolder form is the in-place shape.
      assert script =~ ~s(restic restore "$snapshot:$mount" --target "$mount")
      refute script =~ ~s(restic restore "$snapshot" --target "$mount")
    end

    test "--delete makes the volume BE the snapshot, not a merge into it" do
      script = RestoreJob.script(spec())

      assert script =~ "--delete"
      # --verify reads the written files back: a deliberate second pass,
      # because this is the moment the user's only good copy is written.
      assert script =~ "--verify"
    end

    test "no init guard — a restore names an existing snapshot" do
      script = RestoreJob.script(spec())

      refute script =~ "restic init"
      refute script =~ "restic cat config"
      # ...so a missing repo or a wrong password is a plain failure here.
      assert script =~ ~s([ "$status" -eq 0 ] || finish_failed "restic restore exited $status)
    end

    test "writes a one-line JSON termination message on BOTH paths" do
      script = RestoreJob.script(spec())

      assert script =~ "jq -cn --arg error \"$1\" '{error: $error}' > /dev/termination-log"
      assert script =~ "snapshot_id: $snapshot_id"
      assert script =~ "bytes_restored: $bytes_restored"
      assert script =~ "> /dev/termination-log"
    end

    test "the success message names the snapshot it restored" do
      named = spec(%{snapshot_id: "abcdef123456"})
      script = RestoreJob.script(named)

      # The row records what was restored, not merely that something was.
      assert script =~ ~s(snapshot="abcdef123456")
    end

    test "the error string is restic's last stderr line, capped, one line" do
      script = RestoreJob.script(spec())

      assert script =~ ~s(tail -n 1 "$err")
      assert script =~ "cut -c 1-300"
      # --json makes stderr a JSON event; unwrap .message for the human half.
      message_expr = ~s(jq -r '.message // empty')
      assert script =~ message_expr
      refute script =~ "$RESTIC_PASSWORD"
      refute script =~ "$AWS_SECRET_ACCESS_KEY"
    end

    test "the restic output stream never reaches the pod log" do
      script = RestoreJob.script(spec())

      redirected = ~s(restic restore "$snapshot:$mount" --target "$mount" 2>&1)
      assert script =~ ~s(>"$out")
      refute script =~ redirected
    end

    test "the mount path and snapshot are substituted, never left as tokens" do
      forgejo = spec(%{mount_path: "/forgejo/data"})
      script = RestoreJob.script(forgejo)

      assert script =~ ~s(mount="/forgejo/data")
      refute script =~ "__MOUNT__"
      refute script =~ "__SNAPSHOT__"
    end
  end

  describe "create/3" do
    test "applies the manifest with the fluxvale field manager" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert manifest["kind"] == "Job"
        assert field_manager == "fluxvale"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "Job"}} = RestoreJob.create(%{}, "ns", spec())
    end

    test "a non-2xx response is an error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 422, body: %{"message" => "immutable"}}}
      end)

      assert {:error, %Error{reason: :api_error}} = RestoreJob.create(%{}, "ns", spec())
    end

    test "a transport failure is an error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:error, :timeout} end)

      assert {:error, %Error{reason: :connection_error}} = RestoreJob.create(%{}, "ns", spec())
    end
  end

  describe "get/2" do
    test "returns the Job" do
      expect(Kubereq, :get, fn _req, "ns", "backup-restore" ->
        {:ok, %{status: 200, body: %{"a" => 1}}}
      end)

      assert {:ok, %{"a" => 1}} = RestoreJob.get(%{}, "ns")
    end

    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = RestoreJob.get(%{}, "ns")
    end

    test "other statuses and transport errors are errors" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 500, body: %{}}} end)

      assert {:error, %Error{reason: :api_error}} = RestoreJob.get(%{}, "ns")

      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :closed} end)

      assert {:error, %Error{reason: :connection_error}} = RestoreJob.get(%{}, "ns")
    end
  end

  describe "delete/2" do
    test "200 and 202 both delete" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200}} end)
      assert :ok = RestoreJob.delete(%{}, "ns")

      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 202}} end)
      assert :ok = RestoreJob.delete(%{}, "ns")
    end

    test "404 is :not_found — the caller tolerates it" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = RestoreJob.delete(%{}, "ns")
    end

    test "other statuses and transport errors are errors" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 500, body: %{}}} end)

      assert {:error, %Error{reason: :api_error}} = RestoreJob.delete(%{}, "ns")

      expect(Kubereq, :delete, fn _req, _ns, _name -> {:error, :timeout} end)

      assert {:error, %Error{reason: :connection_error}} = RestoreJob.delete(%{}, "ns")
    end
  end

  describe "pods/2" do
    test "lists the Job's pods by the template's name label" do
      expect(Kubereq, :list, fn _req, "ns", opts ->
        assert opts[:label_selectors] == [{"app.kubernetes.io/name", "backup-restore"}]

        {:ok,
         %{status: 200, body: %{"items" => [%{"metadata" => %{"name" => "backup-restore-x"}}]}}}
      end)

      assert {:ok, [%{"metadata" => %{"name" => "backup-restore-x"}}]} =
               RestoreJob.pods(%{}, "ns")
    end

    # The composition bug, pinned at the attach (the only place a Mimic
    # test can see it): a Job-typed req lists Jobs, whose objects carry no
    # containerStatuses — the outcome read would be nil forever and every
    # successful restore would record as failed.
    test "the list request is Pod-typed, never Job-typed" do
      test_pid = self()

      expect(Kubereq, :attach, fn req, opts ->
        send(test_pid, {:attach_opts, Keyword.take(opts, [:kind, :api_version])})
        req
      end)

      expect(Kubereq, :list, fn _req, "ns", _opts ->
        {:ok, %{status: 200, body: %{"items" => []}}}
      end)

      assert {:ok, []} = RestoreJob.pods(%{}, "ns")
      assert_received {:attach_opts, [api_version: "v1", kind: "Pod"]}
    end

    test "a malformed list body is a validation error" do
      expect(Kubereq, :list, fn _req, _ns, _opts ->
        {:ok, %{status: 200, body: %{"items" => "nope"}}}
      end)

      assert {:error, %Error{reason: :validation_error}} = RestoreJob.pods(%{}, "ns")
    end

    test "non-2xx and transport errors propagate" do
      expect(Kubereq, :list, fn _req, _ns, _opts -> {:ok, %{status: 500, body: %{}}} end)

      assert {:error, %Error{reason: :api_error}} = RestoreJob.pods(%{}, "ns")

      expect(Kubereq, :list, fn _req, _ns, _opts -> {:error, :timeout} end)

      assert {:error, %Error{reason: :connection_error}} = RestoreJob.pods(%{}, "ns")
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

    # A pod owned by the given Job uid — the controller ownerReference
    # shape k8s produces.
    defp owned_pod(job_uid, message) do
      references = [
        %{"apiVersion" => "batch/v1", "kind" => "Job", "uid" => job_uid}
      ]

      # bind-then-call: credo rejects both the nested form and a
      # function-headed pipeline here.
      pod = pod_with_message(message)
      Map.put(pod, "metadata", %{"ownerReferences" => references})
    end

    test "a Job with no verdict is :running — and costs no pod read" do
      stub_job(%{"status" => %{}})
      reject(Kubereq, :list, 3)

      assert {:ok, %{outcome: :running, message: nil}} = RestoreJob.status(%{}, "ns")
    end

    test "a completed Job carries its pod's termination message" do
      message = ~s({"snapshot_id":"abc","bytes_restored":10})
      stub_job(%{"status" => %{"succeeded" => 1}})
      stub_pods([pod_with_message(message)])

      assert {:ok, outcome} = RestoreJob.status(%{}, "ns")
      assert outcome.outcome == :succeeded
      assert outcome.message == message
      assert outcome.exit_code == 0
      assert outcome.reason == "Completed"
      # No label on this Job: the ownership check's nil case (a
      # pre-label object, one-release compatibility).
      assert outcome.run_id == nil
    end

    # The pod-level ownership filter (the backup builder's identical
    # review fix): a leftover pod must never speak for this Job's run.
    test "a foreign pod's termination never speaks for this Job" do
      owned_message = ~s({"snapshot_id":"owned","bytes_restored":10})
      foreign_message = ~s({"snapshot_id":"foreign","bytes_restored":99})

      stub_job(%{
        "metadata" => %{"uid" => "job-uid-1"},
        "status" => %{"succeeded" => 1}
      })

      # The foreign pod is FIRST — without the owner filter it wins.
      stub_pods([
        owned_pod("job-uid-2", foreign_message),
        owned_pod("job-uid-1", owned_message)
      ])

      assert {:ok, outcome} = RestoreJob.status(%{}, "ns")
      assert outcome.message == owned_message
    end

    # The ownership link: the sweep only attributes a verdict to the row
    # the Job's label names.
    test "the outcome carries the run-id label off the Job" do
      stub_job(%{
        "metadata" => %{"labels" => %{"fluxvale.io/backup-run" => "run-42"}},
        "status" => %{"succeeded" => 1}
      })

      stub_pods([pod_with_message(~s({"snapshot_id":"abc"}))])

      assert {:ok, outcome} = RestoreJob.status(%{}, "ns")
      assert outcome.run_id == "run-42"
    end

    test "a running Job carries no run id — the verdict is not settled yet" do
      stub_job(%{
        "metadata" => %{"labels" => %{"fluxvale.io/backup-run" => "run-42"}},
        "status" => %{}
      })

      assert {:ok, %{outcome: :running, run_id: nil}} = RestoreJob.status(%{}, "ns")
    end

    test "a failed pod is :failed with its exit code and message" do
      message = ~s({"error":"restic restore exited 12: wrong password"})

      stub_job(%{"status" => %{"failed" => 1}})

      stub_pods([
        %{
          "status" => %{
            "containerStatuses" => [
              %{
                "state" => %{
                  "terminated" => %{"exitCode" => 12, "reason" => "Error", "message" => message}
                }
              }
            ]
          }
        }
      ])

      assert {:ok, outcome} = RestoreJob.status(%{}, "ns")
      assert outcome.outcome == :failed
      assert outcome.exit_code == 12
      assert outcome.reason == "Error"
      assert outcome.message == message
    end

    test "a failed Job whose pod never started reports the failure without a message" do
      stub_job(%{
        "status" => %{
          "failed" => 1,
          "conditions" => [
            %{"type" => "Failed", "status" => "True", "reason" => "DeadlineExceeded"}
          ]
        }
      })

      stub_pods([])

      assert {:ok, outcome} = RestoreJob.status(%{}, "ns")
      assert outcome.outcome == :failed
      assert outcome.message == nil
      assert outcome.exit_code == nil
      assert outcome.reason == "BackoffLimitExceeded"
    end

    test "a pod whose container has no terminated state yet is skipped" do
      stub_job(%{"status" => %{"succeeded" => 1}})

      stub_pods([
        %{"status" => %{"containerStatuses" => [%{"state" => %{"running" => %{}}}]}},
        %{"status" => %{}}
      ])

      assert {:ok, outcome} = RestoreJob.status(%{}, "ns")
      assert outcome.outcome == :succeeded
      assert outcome.message == nil
    end

    test "the Complete condition counts as success when the counters are absent" do
      stub_job(%{"status" => %{"conditions" => [%{"type" => "Complete", "status" => "True"}]}})
      stub_pods([pod_with_message(~s({"snapshot_id":"abc"}))])

      assert {:ok, %{outcome: :succeeded, message: msg}} = RestoreJob.status(%{}, "ns")
      assert msg =~ "abc"
    end

    test "a pod read failure propagates (the sweep retries)" do
      stub_job(%{"status" => %{"succeeded" => 1}})

      stub(Kubereq, :list, fn _req, _ns, _opts -> {:error, :econnrefused} end)

      assert {:error, %Error{reason: :connection_error}} = RestoreJob.status(%{}, "ns")
    end

    test "a Job read failure propagates" do
      stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = RestoreJob.status(%{}, "ns")
    end
  end

  describe "verdict/1" do
    test "zero counters are not a verdict" do
      assert RestoreJob.verdict(%{"status" => %{"succeeded" => 0, "failed" => 0}}) == :running
      assert RestoreJob.verdict(%{}) == :running
    end

    test "non-zero counters are" do
      assert RestoreJob.verdict(%{"status" => %{"succeeded" => 1}}) == :succeeded
      assert RestoreJob.verdict(%{"status" => %{"failed" => 1}}) == :failed
    end
  end

  describe "run_id/1" do
    test "reads the ownership label off a Job object" do
      assert RestoreJob.run_id(%{
               "metadata" => %{"labels" => %{"fluxvale.io/backup-run" => "run-42"}}
             }) == "run-42"
    end

    test "nil for a Job without the label" do
      assert RestoreJob.run_id(%{"metadata" => %{"labels" => %{}}}) == nil
      assert RestoreJob.run_id(%{}) == nil
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "batch/v1"
      assert opts[:kind] == "Job"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)
    RestoreJob.get(%{}, "ns")
  end
end

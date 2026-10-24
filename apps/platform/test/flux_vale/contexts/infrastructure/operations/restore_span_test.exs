defmodule FluxVale.Infrastructure.Operations.RestoreSpanTest do
  @moduledoc """
  The `instance.restore` span (#222, ADR-0037 §5) — the same shape as
  deploy/reconcile/backup (ADR-0012 Am. 1): one span per restore attempt,
  carrying the instance's identity.

  `FluxVale.TestSupport.Tracing` swaps the batch exporter VM-globally —
  hence `async: false`. Matchers scope on the unique instance id, never
  just the span name.
  """

  use FluxVale.DataCase, async: false
  use Mimic

  import FluxVale.TestSupport.Tracing,
    only: [attribute_map: 1, refute_span_matching: 3, span_matching: 3]

  alias FluxVale.TestSupport.Tracing

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.RestoreJob
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RestoreInstanceBackup
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    Tracing.export_spans_to(self())

    on_exit(fn ->
      Tracing.restore()
    end)

    :ok
  end

  defp user do
    User.create!("span-restore-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp restorable! do
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "Spanned Restore", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    running =
      instance
      |> InstanceFixtures.pin!(
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now()
      )
      |> InstanceFixtures.walk_to!(:running)

    BackupSetting
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        access_key_id: "AKIAIOSFODNN7EXAMPLE"
      },
      authorize?: false
    )
    |> Ash.create!()

    BackupRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        kind: :scheduled,
        status: :succeeded,
        started_at: DateTime.utc_now()
      },
      authorize?: false
    )
    |> Ash.create!()
    |> then(fn run ->
      run
      |> Ash.Changeset.for_update(:update, %{snapshot_id: "6b757e02"}, authorize?: false)
      |> Ash.update!()
    end)

    running
  end

  defp stub_restore_cluster do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
    stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
  end

  test "the restore orchestration is one span carrying instance identity" do
    stub_restore_cluster()
    instance = restorable!()

    assert {:ok, %BackupRun{}} = RestoreInstanceBackup.call(instance)

    span = span_matching("instance.restore", "instance.id", instance.id)
    attributes = attribute_map(span)

    assert Map.get(attributes, "instance.id") == instance.id
    assert attributes["instance.slug"] == instance.slug
    assert attributes["instance.namespace"] == "fluxvale-app-#{instance.id}"
    # The pre-restore status travels on the span — the fact the whole
    # release path keys on.
    assert attributes["instance.status"] == "running"
  end

  test "a refused restore still opens its span (the guard's answer is traceable)" do
    instance = restorable!()

    # :lost is a legal successor of :running and is not restorable —
    # restoring onto a volume the platform cannot even see would be a lie.
    {:ok, lost} = InstanceK8s.update_status(instance, :lost, nil)

    assert {:error, :not_restorable} = RestoreInstanceBackup.call(lost)

    span = span_matching("instance.restore", "instance.id", instance.id)
    assert attribute_map(span)["instance.status"] == "lost"
  end

  test "a guard rejection before any write opens no span for a different instance" do
    stub_restore_cluster()
    instance = restorable!()

    assert {:ok, _run} = RestoreInstanceBackup.call(instance)

    # Names repeat across the suite's history in the shared batch buffer —
    # the matcher scopes on this run's instance id.
    refute_span_matching("instance.restore", "instance.id", Ash.UUID.generate())
  end
end

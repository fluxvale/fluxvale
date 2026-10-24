defmodule FluxVale.Infrastructure.BackupRunTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("runs-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp base! do
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    version
  end

  defp instance!(version, owner) do
    instance =
      Instance.create!(
        %{
          name: "Run history #{System.unique_integer()}",
          app_version_id: version.id,
          env_vars: %{}
        },
        actor: owner
      )

    InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")
  end

  defp create(instance, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{instance_id: instance.id, kind: :manual, started_at: DateTime.utc_now()},
        Map.new(overrides)
      )

    BackupRun
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create()
  end

  describe "create/1" do
    test "defaults to :pending with no outcome fields" do
      instance = instance!(base!(), user())

      assert {:ok, run} = create(instance)
      assert run.status == :pending
      assert run.kind == :manual
      assert run.snapshot_id == nil
      assert run.bytes_processed == nil
      assert run.bytes_added == nil
      assert run.error_summary == nil
      assert run.finished_at == nil
    end

    test "accepts both kinds" do
      version = base!()
      owner = user()

      assert {:ok, scheduled} = create(instance!(version, owner), %{kind: :scheduled})
      assert scheduled.kind == :scheduled

      assert {:ok, manual} = create(instance!(version, owner), %{kind: :manual})
      assert manual.kind == :manual
    end

    test "rejects an unknown kind — :restore lands with its own slice" do
      instance = instance!(base!(), user())

      assert {:error, %Ash.Error.Invalid{}} = create(instance, %{kind: :restore})
    end

    test "error_summary is a finalize field: not creatable, capped at 500 on update" do
      instance = instance!(base!(), user())

      # A run is born outcome-free — the sweep's finalize is the only
      # writer of the verdict fields.
      assert {:error, %Ash.Error.Invalid{}} =
               create(instance, %{error_summary: "too early"})

      {:ok, run} = create(instance)

      assert {:ok, capped} =
               run
               |> Ash.Changeset.for_update(
                 :update,
                 %{status: :failed, error_summary: String.duplicate("x", 500)},
                 authorize?: false
               )
               |> Ash.update()

      assert String.length(capped.error_summary) == 500

      assert {:error, %Ash.Error.Invalid{}} =
               run
               |> Ash.Changeset.for_update(
                 :update,
                 %{error_summary: String.duplicate("x", 501)},
                 authorize?: false
               )
               |> Ash.update()
    end

    test "an instance destroy takes its runs along (cascade)" do
      instance = instance!(base!(), user())
      assert {:ok, _run} = create(instance)

      :ok = Ash.destroy!(instance, authorize?: false)

      assert {:ok, []} = Ash.read(BackupRun, authorize?: false)
    end
  end

  describe "update/1 — the finalize writes" do
    test "a successful finalize records snapshot id, bytes, and the finish time" do
      instance = instance!(base!(), user())
      {:ok, run} = create(instance)
      # started_at/finished_at are `:utc_datetime` (second precision).
      finished_at = DateTime.utc_now(:second)

      assert {:ok, done} =
               run
               |> Ash.Changeset.for_update(
                 :update,
                 %{
                   status: :succeeded,
                   snapshot_id: "6b757e02",
                   bytes_processed: 2048,
                   bytes_added: 1024,
                   finished_at: finished_at
                 },
                 authorize?: false
               )
               |> Ash.update()

      assert done.status == :succeeded
      assert done.snapshot_id == "6b757e02"
      assert done.bytes_processed == 2048
      assert done.bytes_added == 1024
      assert done.finished_at == finished_at
    end

    test "negative byte counts are rejected" do
      instance = instance!(base!(), user())
      {:ok, run} = create(instance)

      assert {:error, %Ash.Error.Invalid{}} =
               run
               |> Ash.Changeset.for_update(:update, %{bytes_added: -1}, authorize?: false)
               |> Ash.update()
    end
  end

  describe "read :recent_for_instance" do
    test "returns the instance's runs newest first, capped by the limit" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      other = instance!(version, owner)

      now = DateTime.utc_now(:second)
      {:ok, oldest} = create(instance, %{started_at: DateTime.add(now, -3600, :second)})
      {:ok, newest} = create(instance, %{started_at: now})
      {:ok, middle} = create(instance, %{started_at: DateTime.add(now, -600, :second)})
      {:ok, _theirs} = create(other, %{started_at: now})

      assert [first, second, third] =
               BackupRun.recent_for_instance!(instance.id, 10, authorize?: false)

      assert first.id == newest.id
      assert second.id == middle.id
      assert third.id == oldest.id

      assert [only] = BackupRun.recent_for_instance!(instance.id, 1, authorize?: false)
      assert only.id == newest.id
    end

    test "the limit argument is bounded 1..100" do
      instance = instance!(base!(), user())

      assert_raise Ash.Error.Invalid, fn ->
        BackupRun.recent_for_instance!(instance.id, 0, authorize?: false)
      end

      assert_raise Ash.Error.Invalid, fn ->
        BackupRun.recent_for_instance!(instance.id, 101, authorize?: false)
      end
    end
  end

  describe "read :active" do
    test "returns pending and running runs only" do
      instance = instance!(base!(), user())

      {:ok, pending} = create(instance, %{status: :pending})
      {:ok, running} = create(instance, %{status: :running})
      {:ok, _succeeded} = create(instance, %{status: :succeeded})
      {:ok, _failed} = create(instance, %{status: :failed})

      active = BackupRun.active!(authorize?: false)

      ids =
        active
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([pending.id, running.id])
    end
  end

  describe "policies" do
    test "an org member reads their instance's runs" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      {:ok, run} = create(instance)

      assert {:ok, [read]} = BackupRun.recent_for_instance(instance.id, 10, actor: owner)
      assert read.id == run.id
    end

    test "an outsider reads an empty history — a list read filters, it never 404s" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      create(instance)

      stranger = user()

      # Same stance as the ledger's wallet page (#123): the instance page
      # is the authorization boundary, so a filtered list is honest here
      # and a Forbidden would leak the instance's existence.
      assert {:ok, []} = BackupRun.recent_for_instance(instance.id, 10, actor: stranger)
    end

    test "no actor is Forbidden — reads need an actor" do
      instance = instance!(base!(), user())
      create(instance)

      assert {:error, %Ash.Error.Forbidden{}} = BackupRun.recent_for_instance(instance.id, 10)
    end

    test "every write is system-only, even for the owner" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      {:ok, run} = create(instance)

      assert {:error, %Ash.Error.Forbidden{}} =
               BackupRun
               |> Ash.Changeset.for_create(
                 :create,
                 %{instance_id: instance.id, kind: :manual, started_at: DateTime.utc_now()},
                 actor: owner
               )
               |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} =
               run
               |> Ash.Changeset.for_update(:update, %{status: :succeeded}, actor: owner)
               |> Ash.update()
    end
  end
end

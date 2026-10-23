defmodule FluxVale.Infrastructure.Operations.ConfigureBackupsTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("configure-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # One cluster per test: ResolveCluster pins the only cluster row.
  defp base! do
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    version
  end

  defp instance!(version, owner) do
    instance =
      Instance.create!(
        %{name: "Deployed #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "s3cr3t-value-never-stored"
      },
      Map.new(overrides)
    )
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  defp stub_cluster do
    stub_kubeconfig()
    stub(Secret, :get_data, fn _kc, _ns, _name -> {:error, %Error{reason: :not_found}} end)
    stub(Secret, :create, fn _kc, _ns, _name, _data -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
  end

  describe "call/3 — the happy path" do
    test "composes the repo URL, writes the Secret, widens the quota, upserts the row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()

      expect(Secret, :get_data, fn _kc, ns, "backup-config" ->
        assert ns == instance.namespace
        {:error, %Error{reason: :not_found}}
      end)

      expect(Secret, :create, fn _kc, ns, "backup-config", data ->
        assert ns == instance.namespace

        assert data["RESTIC_REPOSITORY"] ==
                 "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita"

        # 32 bytes CSPRNG, URL-safe base64: 43 chars, no padding
        assert Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, data["RESTIC_PASSWORD"])
        assert data["AWS_ACCESS_KEY_ID"] == "AKIAIOSFODNN7EXAMPLE"
        assert data["AWS_SECRET_ACCESS_KEY"] == "s3cr3t-value-never-stored"
        {:ok, %{}}
      end)

      expect(ResourceQuota, :create, fn _kc, ns, "app-quota", spec ->
        assert ns == instance.namespace
        # allocation (0.5 CPU / 256 MB) + the Job's requests (0.1 / 128)
        assert spec == %{cpu: Decimal.new("0.6"), memory: 384, storage: 10}
        {:ok, %{}}
      end)

      assert {:ok, setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      assert setting.instance_id == instance.id
      assert setting.endpoint == "https://account.r2.cloudflarestorage.com"
      assert setting.bucket == "fluxvale-kavita"
      assert setting.access_key_id == "AKIAIOSFODNN7EXAMPLE"
      assert setting.retention_keep == 7
      assert setting.enabled
    end

    test "a trailing slash on the endpoint and a prefix compose the same way" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

      expect(Secret, :create, fn _kc, _ns, "backup-config", data ->
        assert data["RESTIC_REPOSITORY"] ==
                 "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita/instances/kavita"

        {:ok, %{}}
      end)

      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      params =
        params(%{
          endpoint: "https://account.r2.cloudflarestorage.com/",
          prefix: "instances/kavita"
        })

      assert {:ok, setting} = Infrastructure.configure_backups(instance, params, actor: owner)
      assert setting.prefix == "instances/kavita"
    end

    test "a file-access instance widens the quota by sidecar plus backup requests" do
      version =
        InstanceFixtures.app_version!(default_storage_gb: 10, file_access: true)

      InstanceFixtures.local_cluster!()
      owner = user()

      instance =
        Instance.create!(
          %{name: "Kavita", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      # The instance is what the policies read; re-binding is the same
      # row (pin! returns the updated struct), not a second instance.
      pinned = InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")

      stub_kubeconfig()
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _d -> {:ok, %{}} end)

      # 0.5 CPU / 256 MB allocation + 0.05/64 sidecar + 0.1/128 backup
      expect(ResourceQuota, :create, fn _kc, _ns, "app-quota", spec ->
        assert spec == %{cpu: Decimal.new("0.65"), memory: 448, storage: 10}
        {:ok, %{}}
      end)

      assert {:ok, _setting} = Infrastructure.configure_backups(pinned, params(), actor: owner)
    end
  end

  describe "call/3 — the Secret is get-or-created, never rotated" do
    test "re-saving with a NEW S3 secret preserves the existing repo password byte-for-byte" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

      expect(Secret, :create, fn _kc, _ns, "backup-config", data ->
        send(self(), {:first_password, data["RESTIC_PASSWORD"]})
        {:ok, %{}}
      end)

      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      assert {:ok, _first} = Infrastructure.configure_backups(instance, params(), actor: owner)
      assert_received {:first_password, first_password}
      assert String.length(first_password) == 43

      # Second save: the Secret exists; the form carries a rotated key.
      existing = %{
        "RESTIC_REPOSITORY" => "s3:https://old.example.com/old-bucket",
        "RESTIC_PASSWORD" => first_password,
        "AWS_ACCESS_KEY_ID" => "OLDKEY",
        "AWS_SECRET_ACCESS_KEY" => "old-secret"
      }

      expect(Secret, :get_data, fn _kc, _ns, "backup-config" -> {:ok, existing} end)

      expect(Secret, :create, fn _kc, _ns, "backup-config", data ->
        # The repo password is the repo's identity — byte-for-byte.
        assert data["RESTIC_PASSWORD"] == first_password
        # The rotated S3 secret and the new coordinates land.
        assert data["AWS_SECRET_ACCESS_KEY"] == "rotated-secret"
        assert data["AWS_ACCESS_KEY_ID"] == "ROTATEDKEY"

        assert data["RESTIC_REPOSITORY"] ==
                 "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita"

        {:ok, %{}}
      end)

      rotated =
        params(%{
          access_key_id: "ROTATEDKEY",
          secret_access_key: "rotated-secret",
          retention_keep: 14
        })

      assert {:ok, setting} = Infrastructure.configure_backups(instance, rotated, actor: owner)
      assert setting.retention_keep == 14
      # One row, not two: the second save upserted the first.
      assert {:ok, all} = Ash.read(BackupSetting, authorize?: false)
      assert length(all) == 1
      assert hd(all).id == setting.id
    end

    test "a re-save with no secret key reuses the stored one" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      existing = %{
        "RESTIC_REPOSITORY" => "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita",
        "RESTIC_PASSWORD" => "existing-repo-password",
        "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
        "AWS_SECRET_ACCESS_KEY" => "stored-secret"
      }

      expect(Secret, :get_data, fn _kc, _ns, _n -> {:ok, existing} end)

      expect(Secret, :create, fn _kc, _ns, "backup-config", data ->
        assert data["RESTIC_PASSWORD"] == "existing-repo-password"
        assert data["AWS_SECRET_ACCESS_KEY"] == "stored-secret"
        {:ok, %{}}
      end)

      no_key = Map.delete(params(), :secret_access_key)

      assert {:ok, _setting} = Infrastructure.configure_backups(instance, no_key, actor: owner)
    end

    test "a first save with no secret key is refused before any cluster write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()

      expect(Secret, :get_data, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, :secret_access_key_required} =
               Infrastructure.configure_backups(
                 instance,
                 Map.delete(params(), :secret_access_key),
                 actor: owner
               )

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end
  end

  describe "call/3 — failure paths write no row" do
    test "no namespace yet: :not_deployed, no cluster write" do
      version = base!()
      owner = user()

      instance =
        Instance.create!(
          %{name: "Undeployed", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, :not_deployed} =
               Infrastructure.configure_backups(instance, params(), actor: owner)
    end

    test "a Secret read failure returns the error and writes no row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()

      expect(Secret, :get_data, fn _kc, _ns, _n ->
        {:error, Error.connection_error("api hiccup")}
      end)

      reject(ResourceQuota, :create, 4)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.configure_backups(instance, params(), actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end

    test "a Secret write failure returns the error and writes no row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

      expect(Secret, :create, fn _kc, _ns, _n, _d ->
        {:error, Error.connection_error("secret rejected")}
      end)

      reject(ResourceQuota, :create, 4)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.configure_backups(instance, params(), actor: owner)
    end

    test "a quota failure returns the error and writes no row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _d -> {:ok, %{}} end)

      expect(ResourceQuota, :create, fn _kc, _ns, _n, _spec ->
        {:error, Error.connection_error("quota rejected")}
      end)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.configure_backups(instance, params(), actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end

    test "a kubeconfig failure returns the error and writes no row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)

      assert {:error, %Error{}} =
               Infrastructure.configure_backups(instance, params(), actor: owner)
    end
  end

  describe "policies" do
    test "an outsider is Forbidden before any cluster write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stranger = user()

      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, %Ash.Error.Forbidden{}} =
               Infrastructure.configure_backups(instance, params(), actor: stranger)
    end

    test "an org member saves settings" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()

      assert {:ok, _setting} = Infrastructure.configure_backups(instance, params(), actor: owner)
    end

    test "a member of another org cannot read the instance's settings" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()
      assert {:ok, _setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      stranger = user()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               BackupSetting.get_by_instance(instance.id, actor: stranger)

      assert Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
    end

    test "a non-member of the instance's own org is Forbidden for every write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()
      assert {:ok, setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      stranger = user()

      assert {:error, %Ash.Error.Forbidden{}} =
               setting
               |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: stranger)
               |> Ash.update()

      # A create for someone else's instance: the instance relationship is
      # what the policy reads, so an outsider can't mint a row either.
      other = instance!(version, owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               BackupSetting
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   instance_id: other.id,
                   endpoint: "https://account.r2.cloudflarestorage.com",
                   bucket: "fluxvale-kavita",
                   access_key_id: "AKIAIOSFODNN7EXAMPLE"
                 },
                 actor: stranger
               )
               |> Ash.create()
    end
  end

  describe "disabling" do
    test "enabled: false is a plain row update — no cluster write at all" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()
      assert {:ok, setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      # Disabling touches the row only: the Secret and the quota margin
      # persist so a re-enable reuses the same restic repo (ADR-0037 §4).
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:ok, disabled} =
               setting
               |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: owner)
               |> Ash.update()

      refute disabled.enabled
    end

    test "re-enabling lands on the same row — upsert, not a second insert" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()
      assert {:ok, setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      assert {:ok, disabled} =
               setting
               |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: owner)
               |> Ash.update()

      assert {:ok, reenabled} =
               Infrastructure.configure_backups(
                 instance,
                 Map.put(params(), :enabled, true),
                 actor: owner
               )

      assert reenabled.enabled
      assert reenabled.id == disabled.id
    end
  end

  describe "the DB row never stores a secret" do
    test "the S3 secret and repo password are absent from the persisted row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

      expect(Secret, :create, fn _kc, _ns, _n, data ->
        send(self(), {:secret_password, data["RESTIC_PASSWORD"]})
        {:ok, %{}}
      end)

      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      assert {:ok, setting} = Infrastructure.configure_backups(instance, params(), actor: owner)
      assert_received {:secret_password, password}

      struct_row = Map.from_struct(setting)
      row = Map.drop(struct_row, [:__meta__, :instance])

      refute_password = fn value -> refute value == password end
      refute_password.(row.endpoint)
      refute_password.(row.bucket)
      refute_password.(row.access_key_id)
      refute_password.(row.prefix)

      # Nor the S3 secret key, under any attribute.
      row_values = Map.values(row)
      values = Enum.filter(row_values, &is_binary/1)
      refute "s3cr3t-value-never-stored" in values

      # The access key *id* is the only credential-shaped value, and it
      # is only an identifier (ADR-0037 §4).
      assert row.access_key_id == "AKIAIOSFODNN7EXAMPLE"
    end
  end
end

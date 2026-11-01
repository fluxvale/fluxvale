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
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    user =
      User.create!("configure-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

    # The paid gate under test reads the org's ledger: the suite's
    # default user is a paid one (the never-paid shapes are built
    # inside their own tests).
    BillingFixtures.mark_user_paid!(user)

    user
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

  describe "call/3 — validate before any cluster write" do
    test "a credentialed endpoint is rejected and writes neither a Secret nor a row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      # The one fence this operation exists to hold: a userinfo rides the
      # repo URL, so restic would log it on every run.
      assert {:error, %Ash.Changeset{}} =
               Infrastructure.configure_backups(
                 instance,
                 params(%{endpoint: "https://user:password@account.r2.cloudflarestorage.com"}),
                 actor: owner
               )

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end

    test "a path-bearing endpoint is rejected before any cluster write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      # restic parses the first path segment as the bucket — "gateway
      # style" endpoints silently select the wrong repo.
      assert {:error, %Ash.Changeset{}} =
               Infrastructure.configure_backups(
                 instance,
                 params(%{endpoint: "https://gateway.example.com/s3"}),
                 actor: owner
               )

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end

    test "an out-of-range retention is rejected before any cluster write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, %Ash.Changeset{}} =
               Infrastructure.configure_backups(instance, params(%{retention_keep: 99}),
                 actor: owner
               )
    end

    test "a typo'd bucket leaves the stored repo URL untouched" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()
      assert {:ok, _setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      # The stored Secret is the good repo; a bad bucket must not
      # rewrite RESTIC_REPOSITORY to a repo the row doesn't name.
      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, %Ash.Changeset{}} =
               Infrastructure.configure_backups(instance, params(%{bucket: "NOT_A_BUCKET"}),
                 actor: owner
               )

      assert {:ok, stored} = BackupSetting.get_by_instance(instance.id, authorize?: false)
      assert stored.bucket == "fluxvale-kavita"
    end

    test "a partial save merges over the stored row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()
      assert {:ok, _setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      # The Secret from the first save is still in the namespace.
      stored_secret = %{
        "RESTIC_REPOSITORY" => "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita",
        "RESTIC_PASSWORD" => "stored-repo-password",
        "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
        "AWS_SECRET_ACCESS_KEY" => "s3cr3t-value-never-stored"
      }

      expect(Secret, :get_data, fn _kc, _ns, _n -> {:ok, stored_secret} end)

      # No endpoint/bucket/keys in this save — the row's values carry them,
      # so RESTIC_REPOSITORY is composed from the MERGED settings.
      expect(Secret, :create, fn _kc, _ns, "backup-config", data ->
        assert data["RESTIC_REPOSITORY"] ==
                 "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita"

        assert data["AWS_ACCESS_KEY_ID"] == "AKIAIOSFODNN7EXAMPLE"
        assert data["RESTIC_PASSWORD"] == "stored-repo-password"
        {:ok, %{}}
      end)

      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      assert {:ok, updated} =
               Infrastructure.configure_backups(instance, %{retention_keep: 14}, actor: owner)

      assert updated.retention_keep == 14
      assert updated.endpoint == "https://account.r2.cloudflarestorage.com"
      assert updated.bucket == "fluxvale-kavita"
    end

    test "prefix: nil clears a stored prefix in both the Secret and the row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()

      assert {:ok, prefixed} =
               Infrastructure.configure_backups(
                 instance,
                 params(%{prefix: "instances/kavita"}),
                 actor: owner
               )

      assert prefixed.prefix == "instances/kavita"

      stored_secret = %{
        "RESTIC_REPOSITORY" =>
          "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita/instances/kavita",
        "RESTIC_PASSWORD" => "stored-repo-password",
        "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
        "AWS_SECRET_ACCESS_KEY" => "s3cr3t-value-never-stored"
      }

      expect(Secret, :get_data, fn _kc, _ns, _n -> {:ok, stored_secret} end)

      expect(Secret, :create, fn _kc, _ns, "backup-config", data ->
        assert data["RESTIC_REPOSITORY"] ==
                 "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita"

        {:ok, %{}}
      end)

      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      assert {:ok, cleared} =
               Infrastructure.configure_backups(instance, params(%{prefix: nil}), actor: owner)

      assert cleared.prefix == nil
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

    test "a blank secret_access_key keeps the stored key byte-for-byte" do
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
        # A blank form field is "leave it alone", never "set it empty",
        # nor a regenerated repo password.
        assert data["AWS_SECRET_ACCESS_KEY"] == "stored-secret"
        assert data["RESTIC_PASSWORD"] == "existing-repo-password"
        {:ok, %{}}
      end)

      assert {:ok, _setting} =
               Infrastructure.configure_backups(
                 instance,
                 params(%{secret_access_key: ""}),
                 actor: owner
               )
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

    test "a first save with a blank secret key is refused too" do
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
                 params(%{secret_access_key: ""}),
                 actor: owner
               )
    end

    test "a stored Secret with no AWS_SECRET_ACCESS_KEY is refused on re-save" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()

      existing = %{
        "RESTIC_REPOSITORY" => "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita",
        "RESTIC_PASSWORD" => "existing-repo-password",
        "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE"
      }

      expect(Secret, :get_data, fn _kc, _ns, _n -> {:ok, existing} end)

      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, :secret_access_key_required} =
               Infrastructure.configure_backups(
                 instance,
                 Map.delete(params(), :secret_access_key),
                 actor: owner
               )
    end

    test "a stored Secret with no RESTIC_PASSWORD is corrupt, not rotatable" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_kubeconfig()

      existing = %{
        "RESTIC_REPOSITORY" => "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita",
        "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
        "AWS_SECRET_ACCESS_KEY" => "stored-secret"
      }

      expect(Secret, :get_data, fn _kc, _ns, _n -> {:ok, existing} end)

      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      # Regenerating the password would orphan every snapshot in the
      # user's bucket — fail loudly and rotate nothing.
      assert {:error, :secret_corrupt} =
               Infrastructure.configure_backups(instance, params(), actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end
  end

  describe "call/3 — failure paths write no row" do
    test "a first save missing a required coordinate is rejected before any cluster write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      # Nothing in the row to merge from: the changeset answers, and the
      # cluster is never touched.
      assert {:error, %Ash.Changeset{} = changeset} =
               Infrastructure.configure_backups(instance, %{}, actor: owner)

      refute changeset.valid?

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end

    test "an unreadable instance id fails the read, not the cluster" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      # A malformed id (a corrupted caller, not a stranger) is an
      # Invalid-Argument read failure — surfaced as-is before any write.
      assert {:error, %Ash.Error.Invalid{}} =
               Infrastructure.configure_backups(
                 %{instance | id: "not-a-uuid"},
                 params(),
                 actor: owner
               )
    end

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
    test "an outsider is Forbidden, with a plain-words reason, before any cluster write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stranger = user()

      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, %Ash.Error.Forbidden{} = error} =
               Infrastructure.configure_backups(instance, params(), actor: stranger)

      assert Exception.message(error) =~ "belong to another organization"
    end

    test "an outsider cannot slip past the ownership read behind authorize?: false" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stranger = user()

      stub_cluster()
      assert {:ok, setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      # A caller forwarding another caller's bypass must not launder a
      # stranger's actor — the read above still authorizes.
      assert {:error, %Ash.Error.Forbidden{}} =
               Infrastructure.configure_backups(
                 instance,
                 params(),
                 actor: stranger,
                 authorize?: false
               )

      assert {:ok, reloaded} = BackupSetting.get_by_instance(instance.id, authorize?: false)
      assert reloaded.updated_at == setting.updated_at
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

  describe "call/3 — the paid gate" do
    test "a never-paid member's first save is Forbidden, with the fix in the message" do
      version = base!()

      owner =
        User.create!("never-paid-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      instance = instance!(version, owner)

      # Nothing may touch the cluster for a never-paid org: not even a
      # read of the namespace's Secret.
      reject(K8s, :kubeconfig, 1)
      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, %Ash.Error.Forbidden{} = error} =
               Infrastructure.configure_backups(instance, params(), actor: owner)

      # The denial is the policy class carrying the plain-words fix —
      # the same shape the cross-org refusal uses.
      assert match?(
               %Ash.Error.Forbidden{errors: [%Ash.Error.Forbidden.Policy{}]},
               error
             )

      assert Exception.message(error) =~ "Top up at least $1 to use backups"

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end

    test "a save that lands disabled passes through — pausing is never gated" do
      version = base!()

      owner =
        User.create!("never-paid-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      instance = instance!(version, owner)

      # The existing row (a paid-era configuration): the save below only
      # flips enabled off, which no gate may stop.
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

      # The stored Secret is the repo's identity — the save re-applies
      # it (a disabled landing still writes cluster state as any save
      # does; only the GATE is skipped).
      stub_kubeconfig()

      stub(Secret, :get_data, fn _kc, _ns, _n ->
        {:ok,
         %{
           "RESTIC_REPOSITORY" => "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita",
           "RESTIC_PASSWORD" => "stored-repo-password",
           "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
           "AWS_SECRET_ACCESS_KEY" => "stored-secret"
         }}
      end)

      stub(Secret, :create, fn _kc, _ns, _n, _d -> {:ok, %{}} end)
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      assert {:ok, paused} =
               Infrastructure.configure_backups(instance, %{enabled: false}, actor: owner)

      refute paused.enabled
    end

    test "a never-paid first save landing DISABLED is Forbidden too — zero cluster calls" do
      # The row write is pre-flighted through the resource policies
      # before any cluster touch, and :create is gated outright: a
      # never-paid org cannot mint a row landing disabled any more than
      # one landing enabled (the old enabled-only gate let the Secret
      # and the quota write before the row was refused).
      version = base!()

      owner =
        User.create!("never-paid-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      instance = instance!(version, owner)

      reject(K8s, :kubeconfig, 1)
      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, %Ash.Error.Forbidden{}} =
               Infrastructure.configure_backups(instance, params(%{enabled: false}), actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end

    test "a caller with no actor keeps the internal bypass — no pre-flight" do
      # The bootstrap shape: no actor, no gate — the internal bypass
      # saves land through the same cluster steps (the row write runs
      # authorize?: false; the resource policies are not consulted).
      version = base!()

      owner =
        User.create!("bypass-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      instance = instance!(version, owner)

      stub_cluster()

      # The bypass shape: no actor AND the caller's own authorize?:
      # false — the ownership read, the merge, and the row write all
      # run system-side, and the pre-flight does not gate them.
      assert {:ok, _setting} =
               Infrastructure.configure_backups(instance, params(), authorize?: false)
    end

    test "a never-paid member's edit that STAYS enabled is Forbidden — zero cluster calls" do
      # The legacy/lapsed shape: a settings row whose org never paid, an
      # ordinary coordinates edit that keeps `enabled` true. The
      # pre-flight refuses it through the update policies before any
      # cluster touch — the pause below is the ONLY ungated save.
      version = base!()

      owner =
        User.create!("never-paid-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      instance = instance!(version, owner)

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

      reject(K8s, :kubeconfig, 1)
      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)
      reject(ResourceQuota, :create, 4)

      assert {:error, %Ash.Error.Forbidden{errors: [%Ash.Error.Forbidden.Policy{}]}} =
               Infrastructure.configure_backups(
                 instance,
                 %{retention_keep: 14},
                 actor: owner
               )
    end

    test "a paid member's first save proceeds to the cluster" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()

      assert {:ok, _setting} = Infrastructure.configure_backups(instance, params(), actor: owner)
    end
  end

  describe "disabling and removing" do
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

    test "remove_backup_settings is a member-policied row delete with no cluster write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()
      assert {:ok, setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      # The Secret persists (same stance as disable): nothing invents a
      # new credential behind the user's back.
      reject(Secret, :delete, 3)
      reject(ResourceQuota, :create, 4)

      assert :ok = Infrastructure.remove_backup_settings(setting, actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)
    end

    test "an outsider cannot remove someone else's settings" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      stub_cluster()
      assert {:ok, setting} = Infrastructure.configure_backups(instance, params(), actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Infrastructure.remove_backup_settings(setting, actor: user())

      assert {:ok, _still_there} = BackupSetting.get_by_instance(instance.id, authorize?: false)
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

      # Nor the S3 secret key, under any attribute.
      row_values = Map.values(row)
      values = Enum.filter(row_values, &is_binary/1)
      refute "s3cr3t-value-never-stored" in values

      # The access key *id* is the only credential-shaped value, and it
      # is only an identifier (ADR-0037 §4).
      assert row.access_key_id == "AKIAIOSFODNN7EXAMPLE"

      # The leak this row could actually take: a credential riding the
      # endpoint (F4). It is refused before any write, so the string never
      # reaches a column — the fence, not a coincidence of composition.
      leak = "leaked-secret-#{System.unique_integer()}"

      assert {:error, %Ash.Changeset{}} =
               Infrastructure.configure_backups(
                 instance,
                 params(%{endpoint: "https://fluxvale:#{leak}@s3.example.com"}),
                 actor: owner
               )

      stored = BackupSetting.get_by_instance!(instance.id, authorize?: false)
      struct = Map.from_struct(stored)
      struct_values = Map.values(struct)
      stored_values = Enum.filter(struct_values, &is_binary/1)
      refute leak in stored_values
      assert password not in stored_values
    end
  end
end

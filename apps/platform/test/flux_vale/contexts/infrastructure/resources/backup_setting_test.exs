defmodule FluxVale.Infrastructure.BackupSettingTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import Ash.Resource.Info, only: [attributes: 1]

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("backups-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # One cluster per test: ResolveCluster pins the only cluster row and
  # refuses to choose among several (ADR-0006).
  defp base! do
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    version
  end

  defp instance!(version) do
    Instance.create!(
      %{name: "Backed up #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
      actor: user()
    )
  end

  defp attrs(instance, overrides) do
    Map.merge(
      %{
        instance_id: instance.id,
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        access_key_id: "AKIAIOSFODNN7EXAMPLE"
      },
      Map.new(overrides)
    )
  end

  defp create(instance, overrides \\ %{}) do
    BackupSetting
    |> Ash.Changeset.for_create(:create, attrs(instance, overrides), authorize?: false)
    |> Ash.create()
  end

  defp error_messages(instance, overrides) do
    {:error, error} = create(instance, overrides)

    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map(&Map.get(&1, :message))
  end

  describe "create/1 — defaults" do
    test "retention defaults to 7 days and backups start enabled" do
      instance = instance!(base!())

      assert {:ok, setting} = create(instance)
      assert setting.retention_keep == 7
      assert setting.enabled
      assert setting.prefix == nil
      assert setting.instance_id == instance.id
    end

    test "one settings row per instance (`unique_instance`)" do
      instance = instance!(base!())

      assert {:ok, _setting} = create(instance)
      assert {:error, %Ash.Error.Invalid{}} = create(instance, %{bucket: "another-bucket"})
    end
  end

  describe "create/1 — endpoint validation" do
    test "accepts http and https endpoints, with or without a path" do
      version = base!()
      nano = instance!(version)

      assert {:ok, http} = create(nano, %{endpoint: "http://minio:9000"})
      assert http.endpoint == "http://minio:9000"

      assert {:ok, path} =
               create(instance!(version), %{endpoint: "https://gateway.example.com/s3"})

      assert path.endpoint == "https://gateway.example.com/s3"
    end

    test "rejects a non-http scheme" do
      version = base!()

      messages = error_messages(instance!(version), %{endpoint: "ftp://files.example.com"})
      assert Enum.any?(messages, &(&1 =~ "must be an http:// or https:// URL"))
    end

    test "rejects a bare host with no scheme" do
      version = base!()

      messages =
        error_messages(instance!(version), %{endpoint: "account.r2.cloudflarestorage.com"})

      assert Enum.any?(messages, &(&1 =~ "must be an http:// or https:// URL"))
    end

    test "rejects a scheme with no host" do
      version = base!()

      messages = error_messages(instance!(version), %{endpoint: "https://"})
      assert Enum.any?(messages, &(&1 =~ "must be an http:// or https:// URL"))
    end
  end

  describe "create/1 — bucket validation" do
    test "accepts lowercase, digits, dots and hyphens" do
      instance = instance!(base!())

      assert {:ok, setting} = create(instance, %{bucket: "my.bucket-01"})
      assert setting.bucket == "my.bucket-01"
    end

    test "rejects uppercase, underscores and names outside 3..63 chars" do
      version = base!()

      for bucket <- ["MyBucket", "my_bucket", "ab", String.duplicate("a", 64)] do
        messages = error_messages(instance!(version), %{bucket: bucket})

        assert Enum.any?(messages, &(&1 =~ "must be 3-63 lowercase")),
               "expected #{inspect(bucket)} to be rejected"
      end
    end

    test "rejects names that start or end on a punctuation mark" do
      version = base!()

      for bucket <- ["-bucket", "bucket-", ".bucket", "bucket."] do
        messages = error_messages(instance!(version), %{bucket: bucket})

        assert Enum.any?(messages, &(&1 =~ "must be 3-63 lowercase")),
               "expected #{inspect(bucket)} to be rejected"
      end
    end
  end

  describe "create/1 — retention bounds" do
    test "accepts the inclusive range 2..30" do
      version = base!()

      assert {:ok, two} = create(instance!(version), %{retention_keep: 2})
      assert two.retention_keep == 2

      assert {:ok, thirty} = create(instance!(version), %{retention_keep: 30})
      assert thirty.retention_keep == 30
    end

    test "rejects 1 and 31" do
      version = base!()

      assert {:error, %Ash.Error.Invalid{}} =
               create(instance!(version), %{retention_keep: 1})

      assert {:error, %Ash.Error.Invalid{}} =
               create(instance!(version), %{retention_keep: 31})
    end
  end

  describe "create/1 — prefix validation" do
    test "accepts dot-separated path segments" do
      instance = instance!(base!())

      assert {:ok, setting} = create(instance, %{prefix: "instances/kavita"})
      assert setting.prefix == "instances/kavita"
    end

    test "rejects a leading or trailing slash" do
      version = base!()

      for prefix <- ["/instances", "instances/"] do
        messages = error_messages(instance!(version), %{prefix: prefix})

        assert Enum.any?(messages, &(&1 =~ "must be path segments")),
               "expected #{inspect(prefix)} to be rejected"
      end
    end

    test "rejects spaces and traversal segments" do
      version = base!()

      for prefix <- ["my backups", "../secrets"] do
        messages = error_messages(instance!(version), %{prefix: prefix})

        assert Enum.any?(messages, &(&1 =~ "must be path segments")),
               "expected #{inspect(prefix)} to be rejected"
      end
    end
  end

  describe "the row never carries a secret" do
    test "the attribute list is exactly the public settings set" do
      # The row stores bucket coordinates and the access key *id* only —
      # the S3 secret key and the restic repo password live in the
      # namespace Secret (ADR-0037 §4). An attribute added here that
      # stores a credential fails this test.
      attributes =
        BackupSetting
        |> attributes()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert attributes == [
               :access_key_id,
               :bucket,
               :created_at,
               :enabled,
               :endpoint,
               :id,
               :instance_id,
               :prefix,
               :retention_keep,
               :updated_at
             ]
    end
  end
end

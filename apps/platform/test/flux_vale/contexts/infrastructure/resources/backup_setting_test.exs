defmodule FluxVale.Infrastructure.BackupSettingTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import Ash.Resource.Info, only: [attributes: 1]

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.BillingFixtures
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
    test "accepts http and https endpoints, with or without a port" do
      version = base!()
      nano = instance!(version)

      assert {:ok, http} = create(nano, %{endpoint: "http://minio:9000"})
      assert http.endpoint == "http://minio:9000"

      assert {:ok, https} =
               create(instance!(version), %{endpoint: "https://s3.example.com:443"})

      assert https.endpoint == "https://s3.example.com:443"

      # A trailing slash is legal input; ConfigureBackups drops it.
      assert {:ok, slash} = create(instance!(version), %{endpoint: "https://s3.example.com/"})
      assert slash.endpoint == "https://s3.example.com/"
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

    test "rejects credentials riding the endpoint" do
      version = base!()

      # The row is not a credential's home (ADR-0037 §4): a userinfo
      # would persist the password in the DB and in every restic log line.
      for endpoint <- [
            "https://user:password@account.r2.cloudflarestorage.com",
            "https://access-key@account.r2.cloudflarestorage.com"
          ] do
        messages = error_messages(instance!(version), %{endpoint: endpoint})

        assert Enum.any?(messages, &(&1 =~ "must be an http:// or https:// URL")),
               "expected #{inspect(endpoint)} to be rejected"
      end
    end

    test "rejects a path-bearing endpoint" do
      version = base!()

      # restic reads the first path segment as the bucket — a gateway
      # path silently selects the wrong repo, and an endpoint carrying
      # the bucket doubles it. The bucket is its own attribute.
      for endpoint <- [
            "https://gateway.example.com/s3",
            "https://gateway.example.com/s3/",
            "https://account.r2.cloudflarestorage.com/fluxvale-kavita"
          ] do
        messages = error_messages(instance!(version), %{endpoint: endpoint})

        assert Enum.any?(messages, &(&1 =~ "must be an http:// or https:// URL")),
               "expected #{inspect(endpoint)} to be rejected"
      end
    end

    test "rejects a query or fragment" do
      version = base!()

      for endpoint <- ["https://s3.example.com?x=1", "https://s3.example.com#frag"] do
        messages = error_messages(instance!(version), %{endpoint: endpoint})

        assert Enum.any?(messages, &(&1 =~ "must be an http:// or https:// URL")),
               "expected #{inspect(endpoint)} to be rejected"
      end
    end

    test "rejects an endpoint past a DNS host's length bound" do
      version = base!()

      # max_length covers scheme + host + port; anything longer is not a
      # hostname (and a restic repo URL is not a place for prose).
      long = "https://" <> String.duplicate("a", 250) <> ".example.com"

      messages = error_messages(instance!(version), %{endpoint: long})

      assert Enum.any?(messages, &(&1 =~ "length must be less than or equal to")),
             "expected a max_length rejection, got #{inspect(messages)}"
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

  describe "the enable flip's paid gate" do
    # The panel's pause/resume switch is a plain `:update`, so the paid
    # gate rides the resource's update policy, scoped to the flip to
    # true. Pausing (and every other update) stays member-only.
    test "a never-paid member cannot flip enabled to true" do
      version = base!()

      owner =
        User.create!("flip-unpaid-#{System.unique_integer()}@fluxvale.com", %{},
          authorize?: false
        )

      instance =
        Instance.create!(
          %{name: "Paused #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      {:ok, setting} = create(instance, %{enabled: false})

      assert {:error, %Ash.Error.Forbidden{}} =
               BackupSetting.update(setting, %{enabled: true}, actor: owner)
    end

    test "a never-paid member can still flip enabled to false — pausing is never gated" do
      version = base!()

      owner =
        User.create!("flip-pause-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      instance =
        Instance.create!(
          %{
            name: "Enabled #{System.unique_integer()}",
            app_version_id: version.id,
            env_vars: %{}
          },
          actor: owner
        )

      {:ok, setting} = create(instance)

      assert {:ok, paused} = BackupSetting.update(setting, %{enabled: false}, actor: owner)
      refute paused.enabled
    end

    test "a paid member flips enabled to true" do
      version = base!()

      owner =
        User.create!("flip-paid-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      BillingFixtures.mark_user_paid!(owner)

      instance =
        Instance.create!(
          %{
            name: "Resumed #{System.unique_integer()}",
            app_version_id: version.id,
            env_vars: %{}
          },
          actor: owner
        )

      {:ok, setting} = create(instance, %{enabled: false})

      assert {:ok, resumed} = BackupSetting.update(setting, %{enabled: true}, actor: owner)
      assert resumed.enabled
    end
  end

  describe "destroy/1 — stop backing up entirely" do
    test "a member deletes the row; the instance survives" do
      version = base!()
      owner = user()

      instance =
        Instance.create!(
          %{
            name: "Destroyed #{System.unique_integer()}",
            app_version_id: version.id,
            env_vars: %{}
          },
          actor: owner
        )

      {:ok, setting} = create(instance)

      assert :ok = BackupSetting.destroy(setting, actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               BackupSetting.get_by_instance(instance.id, authorize?: false)

      assert {:ok, _instance} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "an outsider cannot destroy it" do
      version = base!()
      instance = instance!(version)
      {:ok, setting} = create(instance)

      stranger = user()

      assert {:error, %Ash.Error.Forbidden{}} =
               BackupSetting.destroy(setting, actor: stranger)

      assert {:ok, _still_there} = BackupSetting.get_by_instance(instance.id, authorize?: false)
    end
  end
end

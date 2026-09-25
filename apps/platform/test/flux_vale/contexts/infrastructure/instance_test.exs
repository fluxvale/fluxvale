defmodule FluxVale.Infrastructure.InstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures

  # Oban testing :inline runs trigger actions during the entry action —
  # the k8s surface is stubbed wherever a lifecycle action fires a job.
  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _data -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

    stub(Ingress, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Service, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Deployment, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Secret, :delete, fn _kc, _ns, _n -> :ok end)
    stub(PersistentVolumeClaim, :delete, fn _kc, _ns, _n -> :ok end)
    stub(NetworkPolicy, :delete, fn _kc, _ns, _n -> :ok end)
    stub(ResourceQuota, :delete, fn _kc, _ns, _n -> :ok end)
    stub(RoleBinding, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Namespace, :delete, fn _kc, _n -> :ok end)
  end

  defp user do
    User.create!("owner-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp forgejo_version do
    InstanceFixtures.app_version!(
      image: "codeberg.org/forgejo/forgejo:16.0.5",
      port: 3000,
      healthcheck_path: "/api/healthz",
      instance_url_env: "FORGEJO__server__ROOT_URL",
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 512,
      default_storage_gb: 10,
      default_env_vars: %{
        "FORGEJO__security__INSTALL_LOCK" => "true",
        "FORGEJO__database__DB_TYPE" => "sqlite3",
        "FORGEJO__service__DISABLE_REGISTRATION" => false
      },
      configurable_env_vars: %{
        "FORGEJO__mailer__SMTP_PORT" => %{
          label: "SMTP port",
          type: :integer,
          default: 587,
          required: false,
          secret: false
        },
        "FORGEJO__mailer__ENABLED" => %{
          label: "Enable email",
          type: :boolean,
          default: false,
          required: true,
          secret: false
        }
      }
    )
  end

  # System status funnel for preconditions (mirrors the trigger ops).
  defp status!(instance, status, namespace \\ nil) do
    {:ok, updated} = InstanceK8s.update_status(instance, status, namespace, nil)
    updated
  end

  defp created!(attrs \\ %{}) do
    version = forgejo_version()
    InstanceFixtures.local_cluster!()

    base = %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}}
    attrs = Map.merge(base, Map.new(attrs))

    Instance.create!(attrs, actor: user())
  end

  describe "create/1 — blueprint snapshot" do
    test "derives image/port/probes/resources from the AppVersion, pins owner + cluster" do
      instance = created!()

      assert instance.image == "codeberg.org/forgejo/forgejo:16.0.5"
      assert instance.port == 3000
      assert instance.healthcheck_path == "/api/healthz"
      assert instance.cpu_cores == Decimal.new("0.5")
      assert instance.memory_mb == 512
      assert instance.storage_gb == 10
      assert instance.cluster_id
      assert instance.user_id
      assert instance.status == :pending
      assert instance.namespace == nil
      assert instance.running_since == nil
      assert instance.storage_metering_since == nil
    end

    test "merges stringified defaults under user values (user > operator > schema)" do
      instance =
        created!(env_vars: %{"FORGEJO__mailer__SMTP_PORT" => "2525", "USER_EXTRA" => "x"})

      # operator defaults, stringified
      assert instance.env_vars["FORGEJO__security__INSTALL_LOCK"] == "true"
      assert instance.env_vars["FORGEJO__service__DISABLE_REGISTRATION"] == "false"
      # schema defaults fill what the user omits
      assert instance.env_vars["FORGEJO__mailer__ENABLED"] == "false"
      # user values win
      assert instance.env_vars["FORGEJO__mailer__SMTP_PORT"] == "2525"
      assert instance.env_vars["USER_EXTRA"] == "x"
    end

    test "generates a haikunate slug unique per cluster" do
      attrs = build_attrs()

      assert {:ok, first} = Instance.create(attrs, actor: user())
      assert {:ok, second} = Instance.create(attrs, actor: user())

      assert Regex.match?(~r/^[a-z]+-[a-z]+-\d{4}$/, first.slug)
      assert first.slug != second.slug
    end

    test "generate_unique_slug exhausts retries and assumes freedom without a cluster" do
      alias FluxVale.Infrastructure.Instance.GenerateSlug

      assert GenerateSlug.generate_unique_slug("some-cluster", 0) == {:error, :collision}
      assert {:ok, slug} = GenerateSlug.generate_unique_slug(nil)
      assert Regex.match?(~r/^[a-z]+-[a-z]+-\d{4}$/, slug)
    end

    defp build_attrs do
      version = forgejo_version()
      InstanceFixtures.local_cluster!()

      %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}}
    end

    test "rejects schema-invalid env values" do
      # A version whose required var has no default — the only shape a
      # create can leave unmet (schema defaults auto-fill the rest).
      attrs = fn env ->
        version =
          InstanceFixtures.app_version!(
            configurable_env_vars: %{
              "APP_REQUIRED" => %{label: "Required", type: :string, required: true},
              "APP_INT" => %{label: "Int", type: :integer, default: 587},
              "APP_BOOL" => %{label: "Bool", type: :boolean, default: false}
            }
          )

        InstanceFixtures.local_cluster!()
        %{name: "My App", app_version_id: version.id, env_vars: env}
      end

      # required (no default) missing entirely
      missing = attrs.(%{"APP_INT" => "587"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(missing, actor: user())

      assert Enum.any?(errors, &(&1.message =~ "APP_REQUIRED is required"))

      # Empty strings count as missing (a Secret full of blanks serves no one).
      blank = attrs.(%{"APP_REQUIRED" => ""})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(blank, actor: user())

      assert Enum.any?(errors, &(&1.message =~ "APP_REQUIRED is required"))

      bad_int = attrs.(%{"APP_REQUIRED" => "x", "APP_INT" => "not-a-port"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(bad_int, actor: user())

      assert Enum.any?(errors, &(&1.message =~ "APP_INT must be a whole number"))

      bad_bool = attrs.(%{"APP_REQUIRED" => "x", "APP_BOOL" => "yes"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(bad_bool, actor: user())

      assert Enum.any?(errors, &(&1.message =~ ~s(APP_BOOL must be "true" or "false")))
    end

    test "rejects non-string env values (Secrets are strings)" do
      version = forgejo_version()
      InstanceFixtures.local_cluster!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(
                 %{
                   name: "My Forgejo",
                   app_version_id: version.id,
                   env_vars: %{"FORGEJO__mailer__ENABLED" => true}
                 },
                 actor: user()
               )

      assert Enum.any?(errors, &(&1.message =~ "all env var keys and values must be strings"))
    end

    test "requires a real app version" do
      InstanceFixtures.local_cluster!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(
                 %{name: "My Forgejo", app_version_id: Ash.UUID.generate(), env_vars: %{}},
                 actor: user()
               )

      assert Enum.any?(errors, &(&1.message =~ "selected app version not found"))
    end

    test "cluster resolution fails loudly with zero or multiple clusters" do
      version = forgejo_version()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(
                 %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}},
                 actor: user()
               )

      assert Enum.any?(errors, &(&1.message =~ "no cluster is configured"))

      InstanceFixtures.local_cluster!()
      Cluster.create!(%{name: "second"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(
                 %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}},
                 actor: user()
               )

      assert Enum.any?(
               errors,
               &(&1.message =~ "cluster selection is not implemented for multiple clusters")
             )
    end

    test "requires a signed-in actor; the owner is set from the actor" do
      # Ash 3 runs create policies after changes/validations — an actorless
      # create surfaces the user_id presence error, not Forbidden; it fails
      # loudly either way and nothing is written.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(build_attrs())

      assert Enum.any?(errors, &(&1.field == :user_id))
    end
  end

  describe "policies" do
    test "owners read their instances; nobody else does" do
      owner = user()
      version = forgejo_version()
      InstanceFixtures.local_cluster!()

      instance =
        Instance.create!(
          %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      assert {:ok, _mine} = Instance.get_by_id(instance.id, actor: owner)

      # Read policies filter to nothing — the wrapped NotFound shape (v1's
      # known Ash behavior), indistinguishable from a nonexistent row.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Instance.get_by_id(instance.id, actor: user())
    end
  end

  describe "update_status — state machine + anchors" do
    test "pending → deploying → starting → running; anchors land on :running" do
      instance = created!()

      deploying = status!(instance, :deploying, "fluxvale-app-#{instance.id}")
      assert deploying.status == :deploying

      starting = status!(deploying, :starting)
      running = status!(starting, :running)

      assert running.running_since
      assert running.storage_metering_since == running.running_since
    end

    test "leaving :running clears running_since, keeps the storage anchor across stop" do
      instance = created!()

      running =
        instance
        |> status!(:deploying, "fluxvale-app-#{instance.id}")
        |> status!(:starting)
        |> status!(:running)

      stopped = status!(running, :stopped)

      assert stopped.running_since == nil
      assert stopped.storage_metering_since == running.storage_metering_since

      restarted =
        stopped
        |> status!(:starting)
        |> status!(:running)

      # Storage billing spans the stop; the running interval restarts.
      assert restarted.storage_metering_since == running.storage_metering_since
      assert restarted.running_since
    end

    test "rejects invalid transitions; :error and :deleting from anywhere" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(instance, :running, nil, nil)

      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(instance, :stopped, nil, nil)

      assert {:ok, errored} = InstanceK8s.update_status(instance, :error, nil, "boom")
      assert errored.status == :error

      assert {:ok, deleting} = InstanceK8s.update_status(instance, :deleting, nil, nil)
      assert deleting.status == :deleting
    end
  end

  describe "deploy/1" do
    test "lands :deploying with the ADR-0005 namespace, then :starting via the inline trigger" do
      stub_k8s()
      instance = created!()

      {:ok, deploying} = Instance.deploy(instance, actor: user_of(instance))

      assert deploying.status == :deploying
      assert deploying.namespace == "fluxvale-app-#{instance.id}"
      assert deploying.deployed_at

      # :inline runs the trigger during the action — re-fetch for the
      # post-trigger truth (v1 posture).
      {:ok, fresh} = Instance.get_by_id(instance.id, actor: user_of(instance))
      assert fresh.status == :starting
      assert fresh.status_message =~ "awaiting readiness"
    end

    test "rejects deploy outside pending/error" do
      created = created!()
      instance = status!(created, :deploying, "fluxvale-app-#{created.id}")

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.deploy(instance, actor: user_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot deploy instance in deploying"))
    end
  end

  defp user_of(instance) do
    instance
    |> Ash.load!(:user, authorize?: false)
    |> Map.get(:user)
  end

  describe "stop/1 and start/1" do
    test "stop scales to zero and lands :stopped; start scales back to :starting" do
      stub_k8s()

      created = created!()
      deploying = status!(created, :deploying, "fluxvale-app-#{created.id}")

      instance =
        deploying
        |> status!(:starting)
        |> status!(:running)

      expect(Deployment, :scale, fn _kc, ns, "app", 0 ->
        assert String.starts_with?(ns, "fluxvale-app-")
        {:ok, %{}}
      end)

      {:ok, stopped} = Instance.stop(instance, actor: user_of(instance))
      assert stopped.status == :stopped

      expect(Deployment, :scale, fn _kc, _ns, "app", 1 -> {:ok, %{}} end)

      {:ok, started} = Instance.start(stopped, actor: user_of(instance))
      assert started.status == :starting
    end

    test "stop/start guard their states" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.stop(instance, actor: user_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot stop instance in pending"))

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.start(instance, actor: user_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot start instance in pending"))
    end

    test "a failed scale lands :error with the reason" do
      stub_k8s()
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

      created = created!()
      deploying = status!(created, :deploying, "fluxvale-app-#{created.id}")

      instance =
        deploying
        |> status!(:starting)
        |> status!(:running)

      expect(Deployment, :scale, fn _kc, _ns, _n, _r ->
        {:error, K8s.Error.connection_error("cluster unreachable")}
      end)

      {:ok, errored} = Instance.stop(instance, actor: user_of(instance))
      assert errored.status == :error
      assert errored.status_message =~ "Stop failed: cluster unreachable"
    end
  end

  describe "delete/1" do
    test "never-deployed rows hard-delete synchronously" do
      instance = created!()
      owner = user_of(instance)

      assert {:ok, deleted} = Instance.delete(instance.id, actor: owner)
      assert deleted.id == instance.id

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, actor: owner)
    end

    test "deployed rows tear down asynchronously (inline) and hard-delete" do
      stub_k8s()

      created = created!()
      instance = status!(created, :deploying, "fluxvale-app-#{created.id}")

      owner = user_of(instance)

      expect(Namespace, :delete, fn _kc, ns ->
        assert ns == "fluxvale-app-#{instance.id}"
        :ok
      end)

      assert {:ok, deleting} = Instance.delete(instance.id, actor: owner)
      assert deleting.status == :deleting

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, actor: owner)
    end

    test "a row already :deleting is not re-enqueued" do
      stub_k8s()

      created = created!()
      instance = status!(created, :deleting, "fluxvale-app-#{created.id}")

      owner = user_of(instance)

      # Zero teardown deletes expected — the duplicate guard must hold.
      reject(Namespace, :delete, 2)

      assert {:ok, unchanged} = Instance.delete(instance.id, actor: owner)
      assert unchanged.status == :deleting
    end

    test "ownership is enforced by the authorized read inside" do
      instance = created!()

      assert {:error, _denied} = Instance.delete(instance.id, actor: user())
    end
  end

  describe "trigger actions" do
    test "perform_reconcile delegates to the reconciler (cron entry body)" do
      stub_k8s()
      ns = "fluxvale-app-#{:erlang.unique_integer([:positive])}"

      instance =
        created!()
        |> status!(:deploying, ns)
        |> status!(:starting)

      expect(Deployment, :status, fn _kc, _ns, "app" ->
        {:ok, %{replicas: 1, ready: 1, conditions: []}}
      end)

      {:ok, fresh} = Instance.get_by_id(instance.id, actor: user_of(instance))

      fresh
      |> Ash.Changeset.for_update(:perform_reconcile, %{}, authorize?: false)
      |> Ash.update!()

      {:ok, reloaded} = Instance.get_by_id(instance.id, actor: user_of(instance))
      assert reloaded.status == :running
    end

    test "mark_deploy_error lands :error for unexpected job failures" do
      instance = created!()

      instance
      |> Ash.Changeset.for_update(:mark_deploy_error, %{error: %{}}, authorize?: false)
      |> Ash.update!()
      |> then(fn updated ->
        assert updated.status == :error
        assert updated.status_message == "Deploy job failed unexpectedly"
      end)
    end

    test "mark_teardown_error lands :error with a retry hint" do
      instance = created!()

      instance
      |> Ash.Changeset.for_update(:mark_teardown_error, %{error: %{}}, authorize?: false)
      |> Ash.update!()
      |> then(fn updated ->
        assert updated.status == :error
        assert updated.status_message =~ "retry delete"
      end)
    end
  end

  describe "validation callbacks" do
    test "StatusTransition and ValidateEnvVars callbacks" do
      alias FluxVale.Infrastructure.Instance.StatusTransition
      alias FluxVale.Infrastructure.Instance.ValidateEnvVars

      assert StatusTransition.atomic?() == false
      assert [message: st_message, vars: []] = StatusTransition.describe([])
      assert is_binary(st_message)

      assert ValidateEnvVars.atomic?() == false
      assert [message: ev_message, vars: []] = ValidateEnvVars.describe([])
      assert is_binary(ev_message)
    end
  end
end

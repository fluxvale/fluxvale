defmodule FluxVale.Infrastructure.InstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Catalog.Types.FirstRunContract
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
      # Production shape (#181): INSTALL_LOCK and the registration lock
      # live in the first-run contract, not the operator defaults.
      default_env_vars: %{
        "FORGEJO__database__DB_TYPE" => "sqlite3"
      },
      first_run: %{
        "pattern" => "first_registered_user_admin",
        "env" => %{"FORGEJO__security__INSTALL_LOCK" => "true"},
        "forbidden_env" => ["FORGEJO__service__DISABLE_REGISTRATION"],
        "guidance" => "Register first — the first account becomes admin."
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
  # System status funnel for preconditions (mirrors the trigger ops).
  defp status!(instance, status) do
    {:ok, updated} = InstanceK8s.update_status(instance, status, nil)
    updated
  end

  # Namespaced deployed states: namespace is write-once (the deploy
  # action owns it and the inline trigger races past :deploying) — pin
  # via seed after driving status through the funnel.
  defp deployed!(instance, status, namespace) do
    reached = status!(instance, status)
    InstanceFixtures.pin!(reached, namespace: namespace)
  end

  defp created!(attrs \\ %{}) do
    version = forgejo_version()
    InstanceFixtures.local_cluster!()

    base = %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}}
    attrs = Map.merge(base, Map.new(attrs))

    Instance.create!(attrs, actor: user())
  end

  describe "create/1 — blueprint snapshot" do
    test "snapshots the pricing triple — size, cents, and the 1-year clock together (#121)" do
      version = InstanceFixtures.app_version!(monthly_cents: 279, stopped_monthly_cents: 34)
      InstanceFixtures.local_cluster!()

      before = DateTime.utc_now()

      instance =
        Instance.create!(
          %{name: "Priced", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      after_create = DateTime.utc_now()

      size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

      assert instance.size_id == size.id
      assert instance.grandfathered_monthly_cents == 279
      assert instance.grandfathered_stopped_monthly_cents == 34

      # The clock is one year from this create: bounded by year-shifted
      # timestamps captured either side of it.
      assert DateTime.compare(instance.grandfathered_until, DateTime.shift(before, year: 1)) ==
               :gt

      assert DateTime.compare(instance.grandfathered_until, DateTime.shift(after_create, year: 1)) ==
               :lt
    end

    test "derives image/port/probes/resources from the AppVersion, pins owner + cluster" do
      instance = created!()

      assert instance.image == "codeberg.org/forgejo/forgejo:16.0.5"
      assert instance.port == 3000
      assert instance.healthcheck_path == "/api/healthz"
      assert instance.cpu_cores == Decimal.new("0.5")
      assert instance.memory_mb == 512
      assert instance.storage_gb == 10
      assert instance.cluster_id
      assert instance.organization_id
      assert instance.status == :pending
      assert instance.namespace == nil
      assert instance.running_since == nil
      assert instance.storage_metering_since == nil
    end

    test "merges stringified defaults under user values (contract > user > operator > schema)" do
      instance =
        created!(env_vars: %{"FORGEJO__mailer__SMTP_PORT" => "2525", "USER_EXTRA" => "x"})

      # contract env — the guarantee, above every deploy-time layer
      assert instance.env_vars["FORGEJO__security__INSTALL_LOCK"] == "true"
      # operator defaults, stringified
      assert instance.env_vars["FORGEJO__database__DB_TYPE"] == "sqlite3"
      # schema defaults fill what the user omits
      assert instance.env_vars["FORGEJO__mailer__ENABLED"] == "false"
      # user values win over the layers below the contract
      assert instance.env_vars["FORGEJO__mailer__SMTP_PORT"] == "2525"
      assert instance.env_vars["USER_EXTRA"] == "x"
      # the forbidden key never ships — registration-open rides the
      # app's upstream default (#181)
      refute Map.has_key?(instance.env_vars, "FORGEJO__service__DISABLE_REGISTRATION")
    end

    test "rejects user values naming a contract key — loudly, both halves (#181)" do
      attrs = build_attrs()

      # The env half: the guaranteed posture is not a user setting.
      env_half = Map.put(attrs, :env_vars, %{"FORGEJO__security__INSTALL_LOCK" => "false"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(env_half, actor: user())

      assert Enum.any?(
               errors,
               &(&1.message =~ "first-run contract" and
                   &1.message =~ "FORGEJO__security__INSTALL_LOCK")
             )

      # The forbidden half: the #181 failure mode, closed at the seam.
      forbidden_half =
        Map.put(attrs, :env_vars, %{"FORGEJO__service__DISABLE_REGISTRATION" => "true"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(forbidden_half, actor: user())

      assert Enum.any?(
               errors,
               &(&1.message =~ "first-run contract" and
                   &1.message =~ "FORGEJO__service__DISABLE_REGISTRATION")
             )

      # Case-variant spelling of the forbidden key — Forgejo's
      # environment-to-ini lowercases ini sections, so the folded name
      # hits the same setting; the lock folds too (hostile-review
      # finding, #181).
      case_variant_half =
        Map.put(attrs, :env_vars, %{"FORGEJO__Service__DISABLE_REGISTRATION" => "true"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(case_variant_half, actor: user())

      assert Enum.any?(
               errors,
               &(&1.message =~ "first-run contract" and
                   &1.message =~ "FORGEJO__Service__DISABLE_REGISTRATION")
             )
    end

    test "holds the guarantee even for a drifted version (contract merges last, #181)" do
      # A state actions can't produce (ValidateFirstRunEnv rejects the
      # overlap at write time): a version whose operator default
      # contradicts its own contract — forced via seed, same posture
      # as InstanceFixtures.pin!.
      {:ok, contract} =
        FirstRunContract.new(%{
          "pattern" => "first_registered_user_admin",
          "env" => %{"APP__security__INSTALL_LOCK" => "true"},
          "guidance" => "g"
        })

      app = Ash.load!(forgejo_version(), :app, authorize?: false).app

      drifted =
        Ash.Seed.seed!(FluxVale.Catalog.AppVersion, %{
          version: "9.9.9",
          image: "test/image:9.9",
          port: 3000,
          default_env_vars: %{"APP__security__INSTALL_LOCK" => "false"},
          first_run: contract,
          app_id: app.id
        })

      InstanceFixtures.local_cluster!()

      instance =
        Instance.create!(
          %{name: "Drifted", app_version_id: drifted.id, env_vars: %{}},
          actor: user()
        )

      assert instance.env_vars["APP__security__INSTALL_LOCK"] == "true"
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

    test "requires a signed-in actor; the org is resolved from the actor" do
      # Ash 3 runs create policies after changes/validations — an actorless
      # create surfaces the organization_id presence error, not Forbidden;
      # it fails loudly either way and nothing is written.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(build_attrs())

      assert Enum.any?(errors, &(&1.field == :organization_id))
    end

    test "an actor without an org fails loudly (field-scoped, not a crash)" do
      # Ash.seed! — the only way to produce an org-less user: the create
      # action's JIT change always provisions one (state actions can't
      # produce, the documented seed! exception).
      orgless =
        Ash.Seed.seed!(User, %{
          email: "orgless-#{System.unique_integer()}@fluxvale.test"
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.create(build_attrs(), actor: orgless)

      assert Enum.any?(
               errors,
               &(&1.field == :organization_id and &1.message == "is required")
             )
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

    test "a non-member cannot drive lifecycle transitions or delete" do
      owner = user()
      instance = created_with_actor!(owner)
      stranger = user()

      # stop surfaces the pending-state validation before policy; deploy
      # and delete hit the policy (delete via the wrapped NotFound of the
      # authorized read inside the action)
      assert {:error, %Ash.Error.Invalid{}} = Instance.stop(instance, actor: stranger)

      assert {:error, %Ash.Error.Forbidden{}} = Instance.deploy(instance, actor: stranger)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Instance.delete(instance.id, actor: stranger)
    end

    test "list_for_actor scopes to the actor's org — no cross-org bleed" do
      owner = user()
      instance = created_with_actor!(owner)

      assert {:ok, listed} = Instance.list_for_actor(actor: owner)
      assert Enum.map(listed, & &1.id) == [instance.id]

      stranger = user()

      assert {:ok, []} = Instance.list_for_actor(actor: stranger)
    end
  end

  # created!/1 uses its own user; tests needing a SPECIFIC actor create here.
  defp created_with_actor!(actor) do
    version = forgejo_version()
    InstanceFixtures.local_cluster!()

    Instance.create!(
      %{name: "My Forgejo", app_version_id: version.id, env_vars: %{}},
      actor: actor
    )
  end

  describe "update_status — state machine + anchors" do
    test "pending → deploying → starting → running; anchors land on :running" do
      instance = created!()

      deploying = status!(instance, :deploying)
      assert deploying.status == :deploying

      starting = status!(deploying, :starting)
      running = status!(starting, :running)

      assert running.running_since
      assert running.storage_metering_since == running.running_since
    end

    test "leaving :running folds the interval into the unbilled carry, keeps the storage anchor" do
      instance = created!()

      running =
        instance
        |> status!(:deploying)
        |> status!(:starting)
        |> status!(:running)

      stopped = status!(running, :stopped)

      # The interval's time is carried for settlement (#121) — as a
      # duration, so restart churn can never drop it — and the storage
      # anchor spans the stop (the PVC persists).
      assert stopped.running_since == nil
      assert stopped.unbilled_running_usec >= 0
      assert stopped.storage_metering_since == running.storage_metering_since

      restarted =
        stopped
        |> status!(:starting)
        |> status!(:running)

      # Storage billing spans the stop; a fresh running interval opens
      # on top of the still-pending carry (settle consumes both).
      assert restarted.storage_metering_since == running.storage_metering_since
      assert restarted.running_since
      assert DateTime.compare(restarted.running_since, running.running_since) == :gt
      assert restarted.unbilled_running_usec == stopped.unbilled_running_usec
    end

    test "rejects invalid transitions; :error and :deleting from anywhere" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(instance, :running, nil)

      assert {:error, %Ash.Error.Invalid{}} =
               InstanceK8s.update_status(instance, :stopped, nil)

      assert {:ok, errored} = InstanceK8s.update_status(instance, :error, "boom")
      assert errored.status == :error

      assert {:ok, deleting} = InstanceK8s.update_status(instance, :deleting, nil)
      assert deleting.status == :deleting
    end
  end

  describe "deploy/1" do
    test "lands :deploying with the ADR-0005 namespace, then :starting via the inline trigger" do
      stub_k8s()
      instance = created!()

      {:ok, deploying} = Instance.deploy(instance, actor: owner_of(instance))

      assert deploying.status == :deploying
      assert deploying.namespace == "fluxvale-app-#{instance.id}"
      assert deploying.deployed_at

      # :inline runs the trigger during the action — re-fetch for the
      # post-trigger truth (v1 posture).
      {:ok, fresh} = Instance.get_by_id(instance.id, actor: owner_of(instance))
      assert fresh.status == :starting
      assert fresh.status_message =~ "awaiting readiness"
    end

    test "rejects deploy outside pending/error" do
      created = created!()
      instance = deployed!(created, :deploying, "fluxvale-app-#{created.id}")

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.deploy(instance, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot deploy instance in deploying"))
    end
  end

  # The actor for follow-up lifecycle calls, re-derived from the record the
  # way the data model defines ownership: instance → organization → member.
  defp owner_of(instance) do
    org =
      instance
      |> Ash.load!(:organization, authorize?: false)
      |> Map.get(:organization)

    org
    |> Ash.load!(:members, authorize?: false)
    |> Map.get(:members)
    |> List.first()
  end

  describe "stop/1 and start/1" do
    test "stop scales to zero and lands :stopped; start scales back to :starting" do
      stub_k8s()

      created = created!()
      deploying = deployed!(created, :deploying, "fluxvale-app-#{created.id}")

      instance =
        deploying
        |> status!(:starting)
        |> status!(:running)

      expect(Deployment, :scale, fn _kc, ns, "app", 0 ->
        assert String.starts_with?(ns, "fluxvale-app-")
        {:ok, %{}}
      end)

      {:ok, stopped} = Instance.stop(instance, actor: owner_of(instance))
      assert stopped.status == :stopped

      expect(Deployment, :scale, fn _kc, _ns, "app", 1 -> {:ok, %{}} end)

      {:ok, started} = Instance.start(stopped, actor: owner_of(instance))
      assert started.status == :starting
    end

    test "stop/start guard their states" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.stop(instance, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot stop instance in pending"))

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.start(instance, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot start instance in pending"))
    end

    test "a failed scale lands :error with the reason" do
      stub_k8s()
      stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

      created = created!()
      deploying = deployed!(created, :deploying, "fluxvale-app-#{created.id}")

      instance =
        deploying
        |> status!(:starting)
        |> status!(:running)

      expect(Deployment, :scale, fn _kc, _ns, _n, _r ->
        {:error, K8s.Error.connection_error("cluster unreachable")}
      end)

      {:ok, errored} = Instance.stop(instance, actor: owner_of(instance))
      assert errored.status == :error
      assert errored.status_message =~ "Stop failed: cluster unreachable"
    end
  end

  describe "delete/1" do
    test "never-deployed rows hard-delete synchronously" do
      instance = created!()
      owner = owner_of(instance)

      assert {:ok, deleted} = Instance.delete(instance.id, actor: owner)
      assert deleted.id == instance.id

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, actor: owner)
    end

    test "deployed rows tear down asynchronously (inline) and hard-delete" do
      stub_k8s()

      created = created!()
      instance = deployed!(created, :deploying, "fluxvale-app-#{created.id}")

      owner = owner_of(created)

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
      instance = deployed!(created, :deleting, "fluxvale-app-#{created.id}")

      owner = owner_of(created)

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

      created = created!()
      ns = "fluxvale-app-#{created.id}"

      instance =
        created
        |> status!(:deploying)
        |> status!(:starting)
        |> then(&InstanceFixtures.pin!(&1, namespace: ns))

      expect(Deployment, :status, fn _kc, _ns, "app" ->
        {:ok, %{replicas: 1, ready: 1, conditions: []}}
      end)

      {:ok, fresh} = Instance.get_by_id(instance.id, actor: owner_of(instance))

      fresh
      |> Ash.Changeset.for_update(:perform_reconcile, %{}, authorize?: false)
      |> Ash.update!()

      {:ok, reloaded} = Instance.get_by_id(instance.id, actor: owner_of(instance))
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

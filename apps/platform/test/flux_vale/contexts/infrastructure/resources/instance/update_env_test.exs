defmodule FluxVale.Infrastructure.Instance.UpdateEnvTest do
  @moduledoc false

  # #731 T1 (ADR-0052): the in-place env action's behavior — the status
  # matrix, the Secret inside the row transaction, a failed upsert
  # rolling the row back, a refused post-commit restart leaving the
  # row + Secret applied, key-name-only logging, the owned-key rules,
  # and the allowlist re-append.

  use FluxVale.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceEnvDerived
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  @sentinel "sentinel-value-never-logged"

  @sso_schema %{
    "SSO_AUTHORITY" => %{label: "OIDC issuer URL", type: :string},
    "SSO_CLIENT_ID" => %{label: "OIDC client ID", type: :string},
    "SSO_CLIENT_SECRET" => %{label: "OIDC client secret", type: :string, secret: true},
    "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: :boolean, default: false}
  }

  @recipe %{
    kind: "env",
    issuer_env: "SSO_AUTHORITY",
    client_id_env: "SSO_CLIENT_ID",
    client_secret_env: "SSO_CLIENT_SECRET",
    enabled_env: "SSO_ENABLED",
    pkce: true
  }

  setup :verify_on_exit!

  setup do
    InstanceFixtures.local_cluster!()
    {org, user} = BillingFixtures.grant_free_org!()
    BillingFixtures.funded_wallet!(org: org)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    %{user: user}
  end

  defp create!(user, opts \\ []) do
    version = Keyword.get_lazy(opts, :version, fn -> InstanceFixtures.app_version!() end)

    base = %{name: "Env #{System.unique_integer([:positive])}", app_version_id: version.id}

    attrs =
      case Keyword.fetch(opts, :env) do
        {:ok, env} -> Map.put(base, :env_vars, env)
        :error -> base
      end

    created = Instance.create!(attrs, actor: user)

    instance =
      case Keyword.fetch(opts, :status) do
        {:ok, status} -> InstanceFixtures.walk_to!(created, status)
        :error -> created
      end

    if Keyword.get(opts, :pin, false) do
      InstanceFixtures.pin!(instance, namespace: "ns-live")
    else
      instance
    end
  end

  defp update_env(instance, user, set, remove) do
    instance
    |> Ash.Changeset.for_update(:update_env, %{set: set, remove: remove}, actor: user)
    |> Ash.update()
  end

  defp reload!(instance), do: Instance.get_by_id!(instance.id, authorize?: false)

  defp to_status!(instance, status) do
    instance
    |> Ash.Changeset.for_update(:update_status, %{status: status}, authorize?: false)
    |> Ash.update!()
  end

  defp versions!(instance_id) do
    Instance.Version
    |> Ash.Query.filter(version_source_id == ^instance_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp stub_secret(data) do
    stub(Secret, :get_data, fn _kc, _ns, "app-env" -> {:ok, data} end)
  end

  defp expect_upsert do
    expect(Secret, :upsert, fn _kc, _ns, "app-env", data ->
      send(self(), {:upsert, data})
      {:ok, %{}}
    end)
  end

  # The audit line is :info; the test config's level is :warning.
  # Capture-and-restore (the repo's global-state convention).
  defp capture_info_log(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp assert_error(result, message) do
    assert {:error, error} = result
    assert Exception.message(error) =~ message
  end

  defp wire!(instance) do
    PocketIdWiring.record!(
      %{
        instance_id: instance.id,
        pocket_id_instance_id: instance.id,
        pocket_id_client_id: "client-1",
        pocket_id_secret_id: "secret-1"
      },
      authorize?: false
    )
  end

  describe "row-only statuses (pending/error/lost)" do
    test "pending: the row is the whole truth — no Secret, no restart", %{user: user} do
      instance = create!(user, env: %{"KEEP" => "1"})

      assert {:ok, updated} = update_env(instance, user, %{"NEW" => "2"}, ["KEEP"])

      assert updated.status == :pending
      assert updated.env_vars == %{"NEW" => "2"}
      assert reload!(instance).env_vars == %{"NEW" => "2"}
    end

    test "error: the row only", %{user: user} do
      created = create!(user, env: %{"KEEP" => "1"})
      instance = to_status!(created, :error)

      assert {:ok, updated} = update_env(instance, user, %{"NEW" => "2"}, ["KEEP"])
      assert updated.status == :error
      assert reload!(instance).env_vars == %{"NEW" => "2"}
    end

    test "lost: the row only", %{user: user} do
      created = create!(user, status: :running, pin: true, env: %{"KEEP" => "1"})
      instance = to_status!(created, :lost)

      assert {:ok, updated} = update_env(instance, user, %{"NEW" => "2"}, ["KEEP"])
      assert updated.status == :lost
      assert reload!(instance).env_vars == %{"NEW" => "2"}
    end
  end

  describe "live statuses (running/starting): row + Secret + restart" do
    test "running: the Secret is upserted inside the transaction, then the Deployment rolls",
         %{user: user} do
      instance = create!(user, status: :running, pin: true, env: %{"KEEP" => "old"})
      stub_secret(%{"KEEP" => "old", "LIVE_ONLY" => "live"})

      expect(Secret, :upsert, fn _kc, "ns-live", "app-env", data ->
        # The row write and the Secret apply share the transaction:
        # this read (same process/connection) sees the uncommitted env.
        send(self(), {:upsert, data, reload!(instance).env_vars})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, "ns-live", "app" ->
        send(self(), :restarted)
        {:ok, %{}}
      end)

      assert {:ok, updated} = update_env(instance, user, %{"NEW" => "2"}, ["KEEP"])

      assert_received {:upsert, data, env_in_txn}
      assert data == %{"LIVE_ONLY" => "live", "NEW" => "2"}
      assert env_in_txn == %{"NEW" => "2"}
      assert_received :restarted
      assert updated.env_vars == %{"NEW" => "2"}
    end

    test "starting: the same Secret + restart path", %{user: user} do
      instance = create!(user, status: :starting, pin: true)
      stub_secret(%{})
      expect_upsert()
      expect(Deployment, :restart, fn _kc, "ns-live", "app" -> {:ok, %{}} end)

      assert {:ok, updated} = update_env(instance, user, %{"NEW" => "2"}, [])

      assert updated.status == :starting
      assert_received {:upsert, %{"NEW" => "2"}}
      assert reload!(instance).env_vars == %{"NEW" => "2"}
    end

    test "an empty patch writes no Secret and rolls nothing", %{user: user} do
      instance = create!(user, status: :running, pin: true, env: %{"KEEP" => "1"})

      # No Secret/Deployment stubs: either call fails the test.
      assert {:ok, updated} = update_env(instance, user, %{}, [])

      assert updated.env_vars == %{"KEEP" => "1"}
      assert reload!(instance).env_vars == %{"KEEP" => "1"}
    end
  end

  describe "secret-only statuses (stopped/sleeping): row + Secret, no restart" do
    test "stopped", %{user: user} do
      instance = create!(user, status: :stopped, pin: true, env: %{"KEEP" => "1"})
      stub_secret(%{"KEEP" => "1"})
      expect_upsert()

      assert {:ok, updated} = update_env(instance, user, %{"NEW" => "2"}, ["KEEP"])

      assert updated.status == :stopped
      assert_received {:upsert, %{"NEW" => "2"}}
      assert reload!(instance).env_vars == %{"NEW" => "2"}
    end

    test "sleeping", %{user: user} do
      instance = create!(user, status: :sleeping, pin: true)
      stub_secret(%{})
      expect_upsert()

      assert {:ok, updated} = update_env(instance, user, %{"NEW" => "2"}, [])

      assert updated.status == :sleeping
      assert_received {:upsert, %{"NEW" => "2"}}
    end
  end

  describe "busy/deleting refusals" do
    test "deploying refuses with the busy copy", %{user: user} do
      instance = create!(user, status: :deploying, env: %{"KEEP" => "1"})

      assert_error(update_env(instance, user, %{"NEW" => "2"}, []), "busy (deploying)")
      assert reload!(instance).env_vars == %{"KEEP" => "1"}
    end

    test "restoring refuses with the busy copy", %{user: user} do
      instance = create!(user, status: :restoring, env: %{"KEEP" => "1"})

      assert_error(update_env(instance, user, %{"NEW" => "2"}, []), "busy (restoring)")
      assert reload!(instance).env_vars == %{"KEEP" => "1"}
    end

    test "deleting refuses — nothing to update", %{user: user} do
      created = create!(user, env: %{"KEEP" => "1"})
      instance = to_status!(created, :deleting)

      assert_error(update_env(instance, user, %{"NEW" => "2"}, []), "being deleted")
      assert reload!(instance).env_vars == %{"KEEP" => "1"}
    end
  end

  describe "the Secret failure arms" do
    test "a failed upsert rolls the row (and its version) back", %{user: user} do
      instance = create!(user, status: :running, pin: true, env: %{"KEEP" => "1"})
      stub_secret(%{"KEEP" => "1"})

      stub(Secret, :upsert, fn _kc, _ns, _n, _data ->
        {:error, %K8s.Error{status_code: 422, reason: :invalid, message: "no"}}
      end)

      assert_error(
        update_env(instance, user, %{"NEW" => "2"}, ["KEEP"]),
        "nothing was changed"
      )

      assert reload!(instance).env_vars == %{"KEEP" => "1"}
      env_versions = versions!(instance.id)
      refute Enum.any?(env_versions, &(&1.version_action_name == :update_env))
    end

    test "an unreachable cluster refuses before the row write", %{user: user} do
      instance = create!(user, status: :running, pin: true, env: %{"KEEP" => "1"})

      stub(K8s, :kubeconfig, fn _ref ->
        {:error, %K8s.Error{status_code: 503, reason: :unavailable, message: "down"}}
      end)

      assert_error(update_env(instance, user, %{"NEW" => "2"}, []), "cluster is unreachable")
      assert reload!(instance).env_vars == %{"KEEP" => "1"}
    end

    test "a deployed status without a namespace refuses rather than calling K8s", %{user: user} do
      instance = create!(user, status: :running)

      assert_error(update_env(instance, user, %{"NEW" => "2"}, []), "no live namespace")
    end

    test "a missing live Secret on a row with env refuses — redeploy to repair", %{user: user} do
      instance = create!(user, status: :running, pin: true, env: %{"KEEP" => "1"})

      stub(Secret, :get_data, fn _kc, _ns, _n ->
        {:error, %K8s.Error{status_code: 404, reason: :not_found, message: "gone"}}
      end)

      assert_error(
        update_env(instance, user, %{"NEW" => "2"}, []),
        "the instance's live env Secret is missing — redeploy to repair"
      )

      assert reload!(instance).env_vars == %{"KEEP" => "1"}
    end

    test "an empty-row instance creates a missing Secret from the patch", %{user: user} do
      instance = create!(user, status: :running, pin: true)

      stub(Secret, :get_data, fn _kc, _ns, _n ->
        {:error, %K8s.Error{status_code: 404, reason: :not_found, message: "absent"}}
      end)

      expect_upsert()
      stub(Deployment, :restart, fn _kc, "ns-live", "app" -> {:ok, %{}} end)

      assert {:ok, updated} = update_env(instance, user, %{"NEW" => "2"}, [])
      assert updated.env_vars == %{"NEW" => "2"}
      assert_received {:upsert, %{"NEW" => "2"}}
    end
  end

  describe "the post-commit restart" do
    test "a refused restart leaves the row and Secret applied and answers honestly", %{user: user} do
      instance = create!(user, status: :running, pin: true, env: %{"KEEP" => "1"})
      stub_secret(%{"KEEP" => "1"})
      expect_upsert()

      stub(Deployment, :restart, fn _kc, _ns, _n ->
        {:error, %K8s.Error{status_code: 500, reason: :unknown, message: "roll refused"}}
      end)

      assert_error(
        update_env(instance, user, %{"NEW" => "2"}, ["KEEP"]),
        "the environment was saved, but the rolling restart was refused — retry"
      )

      assert_received {:upsert, %{"NEW" => "2"}}
      assert reload!(instance).env_vars == %{"NEW" => "2"}

      env_versions = versions!(instance.id)
      assert Enum.any?(env_versions, &(&1.version_action_name == :update_env))
    end
  end

  describe "validation" do
    test "the create-time schema runs on the merged map", %{user: user} do
      version =
        InstanceFixtures.app_version!(
          configurable_env_vars: %{
            "PORT" => %{label: "Port", type: :integer, required: true}
          }
        )

      instance = create!(user, version: version, env: %{"PORT" => "8080"})

      assert_error(
        update_env(instance, user, %{"PORT" => "abc"}, []),
        "PORT must be a whole number"
      )

      assert_error(update_env(instance, user, %{}, ["PORT"]), "PORT is required")
      assert reload!(instance).env_vars == %{"PORT" => "8080"}
    end

    test "malformed names and values and overlap refuse", %{user: user} do
      instance = create!(user)

      assert_error(update_env(instance, user, %{"BAD-KEY" => "v"}, []), "POSIX-shaped")
      assert_error(update_env(instance, user, %{"NUMBER" => 1}, []), "must be strings")
      assert_error(update_env(instance, user, %{"A" => "1"}, ["A"]), "both set and removed")
      assert reload!(instance).env_vars == %{}
    end

    test "a stored non-string value is an honest error, not a WithClauseError", %{user: user} do
      instance = create!(user, env: %{"KEEP" => "1"})

      # Forge the state a pre-#731/drifted row can hold: the create path
      # validates strings, the system funnel does not re-validate.
      forged =
        instance
        |> Ash.Changeset.for_update(
          :merge_system_env,
          %{env: %{"KEEP" => "1", "BAD" => 123}},
          authorize?: false
        )
        |> Ash.update!()

      assert_error(
        update_env(forged, user, %{"NEW" => "2"}, []),
        "all env var keys and values must be strings"
      )

      assert reload!(instance).env_vars["BAD"] == 123
    end

    test "a wiring read failure fails closed instead of treating the SSO keys as user-owned", %{
      user: user
    } do
      instance = create!(user)

      stub(PocketIdWiring, :get_by_instance, fn _id, _opts ->
        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Forbidden{}]}}
      end)

      assert_error(
        update_env(instance, user, %{"NEW" => "2"}, []),
        "the instance's SSO wiring could not be read — retry"
      )

      # A non-Invalid read failure is the same fail-closed answer.
      stub(PocketIdWiring, :get_by_instance, fn _id, _opts -> {:error, :boom} end)

      assert_error(
        update_env(instance, user, %{"NEW" => "2"}, []),
        "the instance's SSO wiring could not be read — retry"
      )

      assert reload!(instance).env_vars == %{}
    end

    test "a non-member is Forbidden", %{user: user} do
      instance = create!(user)
      {_other_org, stranger} = BillingFixtures.grant_free_org!()

      assert {:error, %Ash.Error.Forbidden{}} =
               update_env(instance, stranger, %{"NEW" => "2"}, [])
    end
  end

  describe "platform-owned keys" do
    test "the recipe keys are user-writable until a wiring row exists, then set refuses",
         %{user: user} do
      version =
        InstanceFixtures.app_version!(
          oidc_wiring: @recipe,
          configurable_env_vars: @sso_schema
        )

      instance =
        create!(user, version: version, env: %{"SSO_CLIENT_ID" => "user-value"})

      assert {:ok, %Instance{}} =
               update_env(instance, user, %{"SSO_CLIENT_ID" => "user-changed"}, [])

      wire!(instance)

      assert {:error, error} =
               update_env(instance, user, %{"SSO_CLIENT_ID" => "platform-takeover"}, [])

      assert Exception.message(error) =~ "managed by the platform"
      assert Exception.message(error) =~ "SSO_CLIENT_ID"
    end

    test "a recipe-key remove is skipped — the platform keeps it", %{user: user} do
      version =
        InstanceFixtures.app_version!(
          oidc_wiring: @recipe,
          configurable_env_vars: @sso_schema
        )

      instance = create!(user, version: version, env: %{"SSO_CLIENT_ID" => "user-value"})
      wire!(instance)

      assert {:ok, updated} = update_env(instance, user, %{}, ["SSO_CLIENT_ID"])
      assert updated.env_vars["SSO_CLIENT_ID"] == "user-value"
      assert reload!(instance).env_vars["SSO_CLIENT_ID"] == "user-value"
    end

    test "a backing-service url_env key refuses a set", %{user: user} do
      version = InstanceFixtures.backing_version!()
      instance = create!(user, version: version)

      assert_error(
        update_env(instance, user, %{"DATABASE_URL" => "postgres://evil"}, []),
        "managed by the platform"
      )
    end

    test "first-run contract keys refuse their halves honestly", %{user: user} do
      version =
        InstanceFixtures.app_version!(
          first_run: %{
            pattern: "first_registered_user_admin",
            env: %{"CONTRACT_KEY" => "true"},
            forbidden_env: ["FORBIDDEN_KEY"],
            guidance: "Register first."
          }
        )

      instance = create!(user, version: version)
      assert reload!(instance).env_vars["CONTRACT_KEY"] == "true"

      assert_error(
        update_env(instance, user, %{"FORBIDDEN_KEY" => "true"}, []),
        "forbidden by the app's first-run contract"
      )

      assert_error(
        update_env(instance, user, %{"forbidden_key" => "true"}, []),
        "forbidden by the app's first-run contract"
      )

      assert_error(
        update_env(instance, user, %{"CONTRACT_KEY" => "false"}, []),
        "fixed by the app's first-run contract and cannot be changed"
      )

      assert_error(
        update_env(instance, user, %{}, ["CONTRACT_KEY"]),
        "fixed by the app's first-run contract and cannot be changed"
      )

      assert_error(
        update_env(instance, user, %{"contract_key" => "false"}, []),
        "fixed by the app's first-run contract and cannot be changed"
      )

      # Forbidden keys are never settable, but a remove is cleanup.
      assert {:ok, %Instance{}} = update_env(instance, user, %{}, ["FORBIDDEN_KEY"])
      assert reload!(instance).env_vars["CONTRACT_KEY"] == "true"
    end

    test "the version's instance_url_env is owned exactly — a lowercase root_url is removable",
         %{user: user} do
      version = InstanceFixtures.app_version!(instance_url_env: "ROOT_URL")
      instance = create!(user, version: version)

      assert_error(
        update_env(instance, user, %{"ROOT_URL" => "https://evil"}, []),
        "managed by the platform"
      )

      assert {:ok, updated} = update_env(instance, user, %{"root_url" => "https://app"}, [])
      assert updated.env_vars["root_url"] == "https://app"

      assert {:ok, removed} = update_env(updated, user, %{}, ["root_url"])
      refute Map.has_key?(removed.env_vars, "root_url")
    end
  end

  describe "host_allowlist_env" do
    test "a patch touching it carries the platform hostname to the Secret, never to the row",
         %{user: user} do
      version = InstanceFixtures.app_version!(host_allowlist_env: "ALLOWED_HOSTS")

      instance =
        create!(user,
          version: version,
          status: :stopped,
          pin: true,
          env: %{"ALLOWED_HOSTS" => "localhost"}
        )

      stub_secret(%{"ALLOWED_HOSTS" => "localhost"})

      expect(Secret, :upsert, 2, fn _kc, _ns, _n, data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
      platform_host = "#{instance.slug}.#{domain}"

      assert {:ok, updated} =
               update_env(instance, user, %{"ALLOWED_HOSTS" => "example.com"}, [])

      assert_received {:upsert, %{"ALLOWED_HOSTS" => set_value}}
      assert set_value == "example.com,#{platform_host}"

      # The row is the user's intent: the composed append is a live
      # Secret projection only, so the next deploy appends exactly once.
      assert updated.env_vars["ALLOWED_HOSTS"] == "example.com"

      reloaded = reload!(instance)
      assert reloaded.env_vars["ALLOWED_HOSTS"] == "example.com"

      composed = InstanceEnvDerived.allowlist_entry(reloaded.env_vars, reloaded, version)
      assert composed["ALLOWED_HOSTS"] == "example.com,#{platform_host}"
      assert length(String.split(composed["ALLOWED_HOSTS"], platform_host)) == 2

      log =
        capture_info_log(fn ->
          assert {:ok, %Instance{}} = update_env(reloaded, user, %{}, ["ALLOWED_HOSTS"])
        end)

      assert_received {:upsert, %{"ALLOWED_HOSTS" => removed_value}}
      assert removed_value == platform_host
      assert reload!(instance).env_vars == %{}
      assert log =~ ~s(composed=["ALLOWED_HOSTS"])
    end

    test "a private, non-live remove drops the key — no platform hostname re-added", %{
      user: user
    } do
      version = InstanceFixtures.app_version!(host_allowlist_env: "ALLOWED_HOSTS")

      created =
        create!(user, version: version, env: %{"ALLOWED_HOSTS" => "localhost"})

      # Private BEFORE the namespace is pinned: set_exposure is
      # attribute-only on a never-deployed row, and no access pairing
      # exists, so the default hostname is not live.
      private =
        created
        |> Ash.Changeset.for_update(:set_exposure, %{exposure: :private}, actor: user)
        |> Ash.update!()

      instance =
        private
        |> InstanceFixtures.walk_to!(:stopped)
        |> InstanceFixtures.pin!(namespace: "ns-live")

      stub_secret(%{"ALLOWED_HOSTS" => "localhost"})

      expect(Secret, :upsert, fn _kc, "ns-live", "app-env", data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      assert {:ok, updated} = update_env(instance, user, %{}, ["ALLOWED_HOSTS"])

      assert updated.env_vars == %{}
      assert reload!(instance).env_vars == %{}

      assert_received {:upsert, data}
      refute Map.has_key?(data, "ALLOWED_HOSTS")

      domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
      refute Enum.any?(data, fn {_key, value} -> value =~ "#{instance.slug}.#{domain}" end)
    end
  end

  describe "audit" do
    test "one info line carries key names, the instance, and the actor — never a value",
         %{user: user} do
      instance = create!(user, env: %{"DROP" => "old", "CHANGE" => "old"})

      log =
        capture_info_log(fn ->
          assert {:ok, %Instance{}} =
                   update_env(
                     instance,
                     user,
                     %{"CHANGE" => "new", "ADD" => @sentinel},
                     ["DROP"]
                   )
        end)

      assert log =~ "instance=#{instance.id}"
      assert log =~ "actor=#{user.id}"
      assert log =~ ~s(added=["ADD"])
      assert log =~ ~s(changed=["CHANGE"])
      assert log =~ ~s(removed=["DROP"])
      refute log =~ @sentinel
    end

    test "a system caller with no actor logs a nil actor", %{user: user} do
      instance = create!(user)

      log =
        capture_info_log(fn ->
          changeset =
            Ash.Changeset.for_update(
              instance,
              :update_env,
              %{set: %{"API_KEY" => "v"}, remove: []},
              authorize?: false
            )

          assert {:ok, %Instance{}} = Ash.update(changeset)
        end)

      assert log =~ "actor= added="
    end

    test "the PaperTrail version redacts the set values", %{user: user} do
      instance = create!(user)

      capture_info_log(fn ->
        assert {:ok, %Instance{}} = update_env(instance, user, %{"API_KEY" => @sentinel}, [])
      end)

      [create_version, env_version] = versions!(instance.id)

      assert create_version.version_action_type == :create
      assert env_version.version_action_name == :update_env
      assert env_version.version_action_inputs["set"] == "REDACTED"
      assert env_version.changes["env_vars"] == "REDACTED"

      refute inspect(Map.from_struct(env_version)) =~ @sentinel
    end

    test "the system env merge redacts its map — the OIDC secret never lands in the version",
         %{user: user} do
      instance = create!(user, env: %{"KEEP" => "1"})

      changeset =
        Ash.Changeset.for_update(
          instance,
          :merge_system_env,
          %{env: %{"SSO_CLIENT_SECRET" => @sentinel, "KEEP" => "1"}},
          authorize?: false
        )

      assert {:ok, %Instance{}} = Ash.update(changeset)

      env_versions = versions!(instance.id)
      merge_version = Enum.find(env_versions, &(&1.version_action_name == :merge_system_env))

      assert merge_version.version_action_inputs["env"] == "REDACTED"
      assert merge_version.changes["env_vars"] == "REDACTED"
      refute inspect(Map.from_struct(merge_version)) =~ @sentinel
    end
  end
end

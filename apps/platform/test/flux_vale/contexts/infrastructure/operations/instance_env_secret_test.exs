defmodule FluxVale.Infrastructure.Operations.InstanceEnvSecretTest do
  @moduledoc false

  # #597 S5: the one env-update + rollout seam — the ONE
  # way a deployed instance's env changes without a re-deploy. Order
  # is the contract under test: Secret merge-upsert (recipe keys only)
  # BEFORE the rolling restart; a failed upsert never rolls; a failed
  # roll leaves the staged Secret (retry converges).

  # Serialized (async: false) — the shared feature-flag row's lock
  # order (the S2/S3/S4 files' note).
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    BillingFixtures.funded_wallet!(org: org)

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    version = InstanceFixtures.app_version!(configurable_env_vars: %{})

    instance =
      version
      |> InstanceFixtures.instance!(owner)
      |> InstanceFixtures.walk_to!(:running)
      |> InstanceFixtures.pin!(namespace: "ns-live")

    %{instance: instance}
  end

  describe "apply_to_running/4" do
    test "merges the given env into the Secret, then rolls — in that order", %{
      instance: instance
    } do
      stub(Secret, :get_data, fn _kc, "ns-live", "app-env" ->
        {:ok, %{"KEEP_ME" => "yes", "SSO_AUTHORITY" => "old"}}
      end)

      expect(Secret, :upsert, fn _kc, "ns-live", "app-env", data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, "ns-live", "app" ->
        # The upsert must ALREADY have happened (the ordering contract):
        # a zero-timeout receive finds the message or fails here — and
        # puts it back for the outer assertion.
        receive do
          {:upsert, _data} = msg -> send(self(), msg)
        after
          0 -> flunk("rolled before the Secret upsert landed")
        end

        send(self(), :rolled)
        {:ok, %{}}
      end)

      :ok = Infrastructure.apply_instance_env(instance, %{"SSO_AUTHORITY" => "https://id"}, [])

      assert_received {:upsert, data}
      assert_received :rolled
      # Only the given keys moved; everything else rode through.
      assert data == %{"KEEP_ME" => "yes", "SSO_AUTHORITY" => "https://id"}
    end

    test "remove_keys strip the Secret entirely (the disconnect's shape)", %{instance: instance} do
      stub(Secret, :get_data, fn _kc, _ns, _n ->
        {:ok, %{"SSO_AUTHORITY" => "x", "SSO_CLIENT_ID" => "y", "SMTP_HOST" => "z"}}
      end)

      expect(Secret, :upsert, fn _kc, _ns, _n, data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      stub(Deployment, :restart, fn _kc, _ns, _n -> {:ok, %{}} end)

      :ok =
        Infrastructure.apply_instance_env(instance, %{}, [
          "SSO_AUTHORITY",
          "SSO_CLIENT_ID"
        ])

      assert_received {:upsert, data}
      assert data == %{"SMTP_HOST" => "z"}
    end

    test "a failed Secret upsert never rolls", %{instance: instance} do
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:ok, %{}} end)

      expect(Secret, :upsert, fn _kc, _ns, _n, _data ->
        {:error, %K8s.Error{status_code: 409, reason: :conflict, message: "no"}}
      end)

      # A restart after a failed upsert fails the test (Mimic rejects
      # un-stubbed calls).
      assert {:error, %K8s.Error{}} =
               Infrastructure.apply_instance_env(instance, %{"SSO_AUTHORITY" => "https://id"}, [])
    end

    test "a failed restart stages the Secret — the honest retry shape", %{instance: instance} do
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:ok, %{"A" => "1"}} end)
      stub(Secret, :upsert, fn _kc, _ns, _n, _data -> {:ok, %{}} end)

      expect(Deployment, :restart, fn _kc, _ns, _n ->
        {:error, %K8s.Error{status_code: 500, reason: :unknown, message: "roll refused"}}
      end)

      assert {:error, %K8s.Error{}} =
               Infrastructure.apply_instance_env(instance, %{"SSO_AUTHORITY" => "https://id"}, [])
    end

    test "a missing Secret reads as empty — the merge carries only the given keys", %{
      instance: instance
    } do
      stub(Secret, :get_data, fn _kc, _ns, _n ->
        {:error, %K8s.Error{status_code: 404, reason: :not_found, message: "no secret"}}
      end)

      expect(Secret, :upsert, fn _kc, _ns, _n, data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      stub(Deployment, :restart, fn _kc, _ns, _n -> {:ok, %{}} end)

      :ok = Infrastructure.apply_instance_env(instance, %{"SSO_AUTHORITY" => "https://id"}, [])

      assert_received {:upsert, data}
      assert data == %{"SSO_AUTHORITY" => "https://id"}
    end

    test "an undeployed instance refuses honestly (the row is the whole truth)", %{
      instance: instance
    } do
      pending =
        instance
        |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
        |> then(&Ash.Changeset.force_change_attribute(&1, :namespace, nil))
        |> Ash.update!()

      assert {:error, :not_deployed} =
               Infrastructure.apply_instance_env(pending, %{"SSO_AUTHORITY" => "https://id"}, [])
    end
  end
end

defmodule FluxVale.Infrastructure.Operations.InstanceEnvSecretConcurrencyTest do
  @moduledoc """
  #731 T1 (ADR-0052 decision 7): the SSO env seam serializes on the
  instance row's `FOR UPDATE` lock, the same lock the public PATCH takes
  inside its own transaction.

  The test pins both halves deterministically on committed rows and two
  real connections:

  - a holder connection takes the row lock and leaves the Secret as the
    PATCH's critical section would (an extra key merged in);
  - an `apply_locked/3` worker on its own connection must not read or
    write the Secret until the holder releases — the blocked read is the
    serialization proof;
  - after release the worker's read sees the first writer's key and its
    merge preserves both keys.

  Uses `Sandbox.checkout(_, sandbox: false)` connections (the
  debit-wallet concurrency pattern); the test sweeps its committed rows
  by id before finishing.
  """

  use FluxVale.DataCase, async: false
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceEnvSecret
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup :set_mimic_global
  setup :verify_on_exit!

  test "the SSO apply waits on the row lock and merges over the first writer" do
    fixture = committed_fixture!()
    on_exit(fn -> cleanup!(fixture) end)

    parent = self()
    {:ok, store} = start_supervised({Agent, fn -> %{"KEEP" => "kept"} end})

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :get_data, fn _kc, _ns, "app-env" ->
      data = Agent.get(store, & &1)
      send(parent, {:secret_read, data})
      {:ok, data}
    end)

    stub(Secret, :upsert, fn _kc, _ns, "app-env", data ->
      Agent.update(store, fn _current -> data end)
      send(parent, {:upsert, data})
      {:ok, %{}}
    end)

    stub(Deployment, :restart, fn _kc, "ns-live", "app" ->
      send(parent, :restarted)
      {:ok, %{}}
    end)

    holder =
      spawn_link(fn ->
        conn = Sandbox.checkout(Repo, sandbox: false)
        send(parent, {:ready, :holder})

        receive do
          :hold ->
            Repo.transaction(fn ->
              Repo.query!(
                "SELECT id FROM instances WHERE id = $1::uuid FOR UPDATE",
                [Ecto.UUID.dump!(fixture.instance_id)]
              )

              # The first writer's Secret state (what the PATCH's
              # lock-protected upsert would leave).
              Agent.update(store, &Map.put(&1, "PATCH_KEY", "patched"))
              send(parent, :patched)

              receive do
                :release -> :ok
              end
            end)

            Sandbox.checkin(Repo, conn)
            send(parent, :holder_done)
        end
      end)

    worker =
      spawn_link(fn ->
        conn = Sandbox.checkout(Repo, sandbox: false)
        send(parent, {:ready, :worker})

        receive do
          :go -> :ok
        end

        send(parent, :worker_applying)
        result = InstanceEnvSecret.apply_locked(fixture.instance, %{"SSO_KEY" => "sso"}, [])
        Sandbox.checkin(Repo, conn)
        send(parent, {:worker_done, result})
      end)

    assert_receive {:ready, :holder}, 5_000
    assert_receive {:ready, :worker}, 5_000

    send(holder, :hold)
    assert_receive :patched, 5_000

    send(worker, :go)
    assert_receive :worker_applying, 5_000

    # Still holding the row lock: the worker neither reads nor writes
    # the Secret and cannot finish.
    refute_receive {:secret_read, _data}, 300
    refute_receive {:upsert, _data}, 0
    refute_receive {:worker_done, _result}, 0

    send(holder, :release)
    assert_receive :holder_done, 5_000

    assert_receive {:worker_done, :ok}, 5_000

    # The worker's read happened only after the lock released, and saw
    # the first writer's key; its merge preserved both.
    assert_receive {:secret_read, %{"KEEP" => "kept", "PATCH_KEY" => "patched"}}

    assert_receive {:upsert, %{"KEEP" => "kept", "PATCH_KEY" => "patched", "SSO_KEY" => "sso"}}

    assert_receive :restarted

    assert Agent.get(store, & &1) ==
             %{"KEEP" => "kept", "PATCH_KEY" => "patched", "SSO_KEY" => "sso"}
  end

  # Seeds through a committed connection: both spawned writers must see
  # the row. Returns the ids cleanup needs.
  defp committed_fixture! do
    committed?(fn ->
      cluster = InstanceFixtures.local_cluster!()
      {org, owner} = BillingFixtures.grant_free_org!()
      BillingFixtures.funded_wallet!(org: org)
      version = InstanceFixtures.app_version!()
      app = Ash.get!(FluxVale.Catalog.App, version.app_id, authorize?: false)

      created =
        Instance.create!(
          %{
            name: "Lock #{System.unique_integer([:positive])}",
            app_version_id: version.id,
            env_vars: %{"KEEP" => "kept"}
          },
          actor: owner
        )

      instance =
        created
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "ns-live")

      %{
        instance: instance,
        instance_id: instance.id,
        user_id: owner.id,
        cluster_id: cluster.id,
        version_id: version.id,
        size_id: version.recommended_size_id,
        app_id: app.id,
        category_id: app.category_id
      }
    end)
  end

  # Runs fun on a real connection whose writes commit immediately. Works
  # from on_exit too — sandbox:false checkouts bypass sandbox ownership.
  defp committed?(fun) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # Children before parents: access routes RESTRICT their instance, the
  # org FKs RESTRICT, the catalog chain RESTRICTs app_versions → apps →
  # categories and app_versions → pricing_sizes. PaperTrail versions
  # nilify on user delete; the local ones are swept by source id.
  defp cleanup!(ids) do
    committed?(fn ->
      user_id = Ecto.UUID.dump!(ids.user_id)
      cluster_id = Ecto.UUID.dump!(ids.cluster_id)
      version_id = Ecto.UUID.dump!(ids.version_id)
      size_id = Ecto.UUID.dump!(ids.size_id)
      app_id = Ecto.UUID.dump!(ids.app_id)
      category_id = Ecto.UUID.dump!(ids.category_id)

      result =
        Repo.query!("SELECT organization_id FROM memberships WHERE user_id = $1", [user_id])

      org_ids = Enum.map(result.rows, fn [id] -> id end)

      Repo.transaction(fn ->
        Repo.query!(
          "DELETE FROM access_routes WHERE instance_id IN (SELECT id FROM instances WHERE organization_id = ANY($1))",
          [org_ids]
        )

        Repo.query!(
          "DELETE FROM instances_versions WHERE version_source_id IN (SELECT id FROM instances WHERE organization_id = ANY($1))",
          [org_ids]
        )

        Repo.query!("DELETE FROM access_gateways WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM instances WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM access_domains WHERE organization_id = ANY($1)", [org_ids])

        Repo.query!(
          "DELETE FROM billing_ledger_entries WHERE wallet_id IN (SELECT id FROM billing_wallets WHERE organization_id = ANY($1))",
          [org_ids]
        )

        Repo.query!("DELETE FROM billing_wallets WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM memberships WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM user_emails WHERE user_id = $1", [user_id])
        Repo.query!("DELETE FROM organizations WHERE id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM users WHERE id = $1", [user_id])

        Repo.query!("DELETE FROM app_versions_versions WHERE version_source_id = $1", [version_id])

        Repo.query!("DELETE FROM app_versions WHERE id = $1", [version_id])
        Repo.query!("DELETE FROM pricing_sizes_versions WHERE version_source_id = $1", [size_id])
        Repo.query!("DELETE FROM pricing_sizes WHERE id = $1", [size_id])
        Repo.query!("DELETE FROM apps_versions WHERE version_source_id = $1", [app_id])
        Repo.query!("DELETE FROM apps WHERE id = $1", [app_id])
        Repo.query!("DELETE FROM categories_versions WHERE version_source_id = $1", [category_id])
        Repo.query!("DELETE FROM categories WHERE id = $1", [category_id])
        Repo.query!("DELETE FROM clusters_versions WHERE version_source_id = $1", [cluster_id])
        Repo.query!("DELETE FROM clusters WHERE id = $1", [cluster_id])
      end)
    end)
  end
end

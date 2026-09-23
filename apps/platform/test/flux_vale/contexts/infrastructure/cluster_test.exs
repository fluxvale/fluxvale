defmodule FluxVale.Infrastructure.ClusterTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster

  defp admin do
    case User.get_by_email("admin@fluxvale.com", authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
    end
  end

  defp regular_user do
    User.create!("regular-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  describe "create/2" do
    test "creates with a nil kubeconfig_ref — the local sentinel (#72)" do
      assert {:ok, cluster} = Cluster.create(%{name: "local"}, authorize?: false)

      assert cluster.name == "local"
      assert cluster.kubeconfig_ref == nil
    end

    test "accepts a kubeconfig_ref for a future remote cluster" do
      assert {:ok, cluster} =
               Cluster.create(%{name: "fastly-eu", kubeconfig_ref: "bws://clusters/eu"},
                 authorize?: false
               )

      assert cluster.kubeconfig_ref == "bws://clusters/eu"
    end

    test "rejects non-URL-shaped names; accepts single-character names" do
      assert {:error, %Ash.Error.Invalid{}} =
               Cluster.create(%{name: "Not A Cluster"}, authorize?: false)

      assert {:ok, single} = Cluster.create(%{name: "a"}, authorize?: false)
      assert single.name == "a"
    end

    test "enforces unique name" do
      Cluster.create!(%{name: "local"}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = Cluster.create(%{name: "local"}, authorize?: false)
    end
  end

  describe "get_by_name/1" do
    test "fetches by name or errors" do
      created = Cluster.create!(%{name: "local"}, authorize?: false)

      assert {:ok, fetched} = Cluster.get_by_name("local", authorize?: false)
      assert fetched.id == created.id

      assert {:error, _not_found} = Cluster.get_by_name("nope", authorize?: false)
    end
  end

  describe "update/2" do
    test "updates kubeconfig_ref; name is immutable (the lookup key)" do
      cluster = Cluster.create!(%{name: "local"}, authorize?: false)

      assert {:ok, updated} =
               Cluster.update(cluster, %{kubeconfig_ref: "bws://clusters/eu"}, authorize?: false)

      assert updated.kubeconfig_ref == "bws://clusters/eu"
      assert updated.name == "local"

      assert {:error, %Ash.Error.Invalid{}} =
               Cluster.update(cluster, %{name: "renamed"}, authorize?: false)
    end
  end

  describe "policy (ADR-0027: admin-only, reads included)" do
    setup do
      %{admin: admin(), regular: regular_user()}
    end

    test "non-admins and anonymous are denied reads too", %{regular: regular} do
      Cluster.create!(%{name: "local"}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(Cluster, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Cluster, authorize?: true)
    end

    test "admins run the full AshAdmin CRUD path", %{admin: admin} do
      assert {:ok, cluster} =
               Cluster.create(%{name: "local"}, actor: admin, authorize?: true)

      assert {:ok, [_row]} = Ash.read(Cluster, actor: admin, authorize?: true)

      assert {:ok, updated} =
               Ash.update(cluster, %{kubeconfig_ref: "bws://clusters/eu"},
                 actor: admin,
                 authorize?: true
               )

      assert updated.kubeconfig_ref == "bws://clusters/eu"

      assert :ok = Ash.destroy(updated, actor: admin, authorize?: true)
    end

    test "non-admins cannot create", %{regular: regular} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Cluster.create(%{name: "local"}, actor: regular, authorize?: true)
    end
  end
end

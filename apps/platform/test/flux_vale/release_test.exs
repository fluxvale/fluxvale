defmodule FluxVale.ReleaseTest do
  @moduledoc """
  The release DB tasks (`FluxVale.Release.migrate/0`, `seed/0`,
  `ensure_cluster/0`). The functions run unchanged under ExUnit —
  `with_repo/2` reuses the already-started test repo — so the suite
  exercises the real code and only the no-Mix release *environment*
  stays untested (#98).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster

  test "migrate/0 is a no-op when all migrations are applied" do
    assert :ok = FluxVale.Release.migrate()
  end

  test "seed/0 brings up the admin + catalog" do
    assert :ok = FluxVale.Release.seed()

    assert %{platform_role: :admin} =
             User.get_by_email!("admin@fluxvale.com", authorize?: false)
  end

  # CLUSTER_NAME is VM-global but read only by ensure_cluster/0, so no
  # async test races these.
  describe "ensure_cluster/0" do
    setup do
      original = System.get_env("CLUSTER_NAME")

      on_exit(fn ->
        case original do
          nil -> System.delete_env("CLUSTER_NAME")
          value -> System.put_env("CLUSTER_NAME", value)
        end
      end)

      :ok
    end

    test "raises when CLUSTER_NAME is unset or empty" do
      System.delete_env("CLUSTER_NAME")

      assert_raise ArgumentError, ~r/CLUSTER_NAME/, fn ->
        FluxVale.Release.ensure_cluster()
      end

      System.put_env("CLUSTER_NAME", "")

      assert_raise ArgumentError, ~r/CLUSTER_NAME/, fn ->
        FluxVale.Release.ensure_cluster()
      end
    end

    test "creates the row by name with a null kubeconfig_ref" do
      System.put_env("CLUSTER_NAME", "bringup-test-01")

      assert :ok = FluxVale.Release.ensure_cluster()

      assert {:ok, %{kubeconfig_ref: nil}} =
               Cluster.get_by_name("bringup-test-01", authorize?: false)
    end

    test "never converges an existing row" do
      existing =
        Cluster.create!(%{name: "bringup-drift-01", kubeconfig_ref: "secrets/ref"},
          authorize?: false
        )

      System.put_env("CLUSTER_NAME", "bringup-drift-01")

      assert :ok = FluxVale.Release.ensure_cluster()

      assert {:ok, %{id: id, kubeconfig_ref: "secrets/ref"}} =
               Cluster.get_by_name("bringup-drift-01", authorize?: false)

      assert id == existing.id
    end
  end
end

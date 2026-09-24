defmodule FluxVale.Seeds.ClusterSeedTest do
  @moduledoc """
  The local cluster seed (`FluxVale.Seeds.seed_local_cluster!/0`) against a
  sandboxed DB — the real helper, so drift between helper and resource
  fails here (#72).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Seeds

  describe "seed_local_cluster!/0" do
    test "creates the local row with nil kubeconfig_ref — the in-cluster sentinel" do
      cluster = Seeds.seed_local_cluster!()

      assert cluster.name == "local"
      assert cluster.kubeconfig_ref == nil
    end

    test "idempotent — a second run returns the existing row, no dupe" do
      first = Seeds.seed_local_cluster!()
      second = Seeds.seed_local_cluster!()

      assert second.id == first.id

      assert [%Cluster{}] = Ash.read!(Cluster, authorize?: false)
    end

    test "does not converge — a deliberately-set ref survives re-seeding" do
      cluster = Seeds.seed_local_cluster!()
      Cluster.update!(cluster, %{kubeconfig_ref: "bws://clusters/eu"}, authorize?: false)

      reseeded = Seeds.seed_local_cluster!()

      assert reseeded.kubeconfig_ref == "bws://clusters/eu"
    end
  end
end

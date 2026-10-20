defmodule FluxVale.BootInvariantsTest do
  @moduledoc false

  # #175: the check /health/ready gates on. Preconditions are built
  # through actions (the fixtures) so the suite fails loudly when the
  # create contracts change; an empty DB is the half-seeded Oct-20
  # shape, not a fixture gap.

  use FluxVale.DataCase, async: true

  alias FluxVale.BootInvariants
  alias FluxVale.TestSupport.InstanceFixtures

  describe "check/0" do
    test ":ok when every invariant holds" do
      InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      assert :ok = BootInvariants.check()
    end

    test "the empty-database case names all three invariants" do
      assert {:error, violations} = BootInvariants.check()

      assert violations == [
               "pricing: no rows — required reference data missing (bin/seed restores it)",
               "catalog: no rows — required reference data missing (bin/seed restores it)",
               "clusters: 0 rows (need exactly one) — bin/ensure-cluster creates the row; extras are removed in AshAdmin"
             ]
    end

    test "present reference data with no cluster row fails on clusters alone" do
      InstanceFixtures.app_version!()

      assert {:error, [violation]} = BootInvariants.check()
      assert violation =~ "clusters: 0 rows"
    end

    test "multiple cluster rows fail as loudly as none" do
      InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()
      InstanceFixtures.local_cluster!()

      assert {:error, [violation]} = BootInvariants.check()
      assert violation =~ "clusters: 2 rows"
    end
  end
end

defmodule FluxVale.Seeds.AdminSeedTest do
  @moduledoc """
  The promotable seed (`FluxVale.Seeds.seed/0` — dev `mix setup` AND the
  release's `bin/seed` run this path) against a sandboxed DB, so drift
  between helper and resources fails here (#98).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Seeds

  require Ash.Query

  describe "seed_admin!/0" do
    test "creates the bootstrap platform admin" do
      :ok = Seeds.seed_admin!()

      assert %{platform_role: :admin} =
               User.get_by_email!("admin@fluxvale.com", authorize?: false)
    end

    test "idempotent — a second run keeps one admin row" do
      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin!()

      assert [%User{}] = users_matching_email()
    end

    test "raises on an existing non-admin occupant of the seed email" do
      User.create!("admin@fluxvale.com", %{platform_role: :user}, authorize?: false)

      assert_raise RuntimeError, ~r/non-admin role/, fn ->
        Seeds.seed_admin!()
      end

      # The squatter is untouched — promotion is an operator decision
      assert [%{platform_role: :user}] = users_matching_email()
    end

    defp users_matching_email do
      User
      |> Ash.Query.filter(email == ^"admin@fluxvale.com")
      |> Ash.read!(authorize?: false)
    end
  end

  describe "seed/0" do
    test "runs admin + catalog — the promotable path, no local-cluster row" do
      :ok = Seeds.seed()

      assert User.get_by_email!("admin@fluxvale.com", authorize?: false)
      # Catalog converged (#70's machinery; Forgejo ships in the YAML)
      assert [_entries] = Ash.read!(FluxVale.Catalog.Category, authorize?: false)
    end
  end
end

defmodule FluxValeWeb.AdminConsoleTest do
  @moduledoc false

  # The exposure registry's parity discipline (#595): the configured
  # ash_domains partition into live, pending, and excluded-by-name.
  # What is ENFORCED, exactly: every configured domain is accounted
  # for (one of the three sets, no orphans), the six-domain target
  # matches the plan's appendix A, and every LIVE domain's resource
  # set equals the domain's real resources in both directions.
  # Pending domains force nothing per-resource until their slice
  # flips them live — and the per-resource exclusion mechanism
  # (Billing/Topup) lands with slice 3, at which point the
  # live-domain arm becomes include-or-exclude-by-name. Plus the
  # registry's own API contract: segment resolution and the policy
  # probe.
  #
  # The parity arms need no DB — they walk compiled modules. visible?
  # needs actors, so it rides the same ConnCase sandbox.

  use FluxValeWeb.ConnCase, async: false

  alias Ash.Domain.Info
  alias FluxVale.Identity.User
  alias FluxValeWeb.AdminConsole

  @n :erlang.unique_integer([:positive])

  # The plan's appendix A target set: six domains in, three out.
  @target_included [
    FluxVale.Ops,
    FluxVale.Catalog,
    FluxVale.Infrastructure,
    FluxVale.Pricing,
    FluxVale.Billing,
    FluxVale.Feedback
  ]

  # Identity carries sessions, tokens, and credentials — the auth
  # surface is never console data (ADR-0027 §3 keeps it out). Accounts
  # is the curated orgs surfaces' lane, not raw tables. Api is
  # machine-client bookkeeping, not operator data.
  @target_excluded [
    FluxVale.Identity,
    FluxVale.Accounts,
    FluxVale.Api
  ]

  describe "the registry parity (every configured domain accounted for)" do
    test "live plus pending is exactly the six-domain target set" do
      domains = AdminConsole.domains()

      live =
        domains
        |> Enum.map(& &1.module)
        |> MapSet.new()

      pending_list = AdminConsole.pending_domains()
      pending = MapSet.new(pending_list)
      included = MapSet.union(live, pending)
      target = MapSet.new(@target_included)

      assert MapSet.equal?(included, target),
             "the included set drifted from the plan's appendix A — a slice flip or a scope change belongs in the registry with its reason"
    end

    test "excluded by name, each with its documented reason" do
      excluded = AdminConsole.excluded_domains()
      excluded_keys = Map.keys(excluded)
      excluded_set = MapSet.new(excluded_keys)
      target = MapSet.new(@target_excluded)

      assert MapSet.equal?(excluded_set, target)

      for {module, reason} <- excluded do
        assert is_binary(reason) and reason != "",
               "#{inspect(module)} needs a documented exclusion reason"
      end
    end

    test "live, pending, and excluded partition the configured ash_domains — nothing undecided" do
      domains = AdminConsole.domains()

      live =
        domains
        |> Enum.map(& &1.module)
        |> MapSet.new()

      pending_list = AdminConsole.pending_domains()
      pending = MapSet.new(pending_list)

      excluded_map = AdminConsole.excluded_domains()

      excluded =
        excluded_map
        |> Map.keys()
        |> MapSet.new()

      assert MapSet.disjoint?(live, pending)
      assert MapSet.disjoint?(live, excluded)
      assert MapSet.disjoint?(pending, excluded)

      configured_list = Application.get_env(:flux_vale, :ash_domains)
      configured = MapSet.new(configured_list)

      accounted =
        live
        |> MapSet.union(pending)
        |> MapSet.union(excluded)

      assert MapSet.equal?(accounted, configured),
             "a configured domain is neither exposed nor excluded — decide in the registry"
    end

    test "every live domain's resources are exactly its real resources — a new resource forces a decision" do
      for domain <- AdminConsole.domains() do
        registered =
          domain.resources
          |> Enum.map(& &1.module)
          |> MapSet.new()

        actual =
          domain.module
          |> Info.resources()
          |> MapSet.new()

        assert MapSet.equal?(registered, actual),
               "#{inspect(domain.module)}: the registry and the domain disagree on resources — include the new resource or exclude it by name with a reason"
      end
    end

    test "a live domain's URL segment is its key, and every entry carries a module" do
      for domain <- AdminConsole.domains() do
        assert is_atom(domain.key)
        assert is_binary(domain.label) and domain.label != ""
        assert function_exported?(domain.module, :module_info, 1)

        for resource <- domain.resources do
          assert is_atom(resource.key)
          assert function_exported?(resource.module, :module_info, 1)
          assert is_map(resource.config)
        end
      end
    end
  end

  describe "segment resolution" do
    test "resolves URL string segments to registry entries" do
      {:ok, entry} = AdminConsole.fetch("ops", "feature_flag")

      assert entry.module == FluxVale.Ops.FeatureFlag
      assert entry.domain.module == FluxVale.Ops
      assert entry.key == :feature_flag
    end

    test "resolves atoms too" do
      {:ok, entry} = AdminConsole.fetch(:ops, :access_rule)
      assert entry.module == FluxVale.Ops.AccessRule
    end

    test "unknown segments answer :error — never an atom, never a guess" do
      assert AdminConsole.fetch("nope", "feature_flag") == :error
      assert AdminConsole.fetch("ops", "nope") == :error
      assert AdminConsole.fetch("nope", "nope") == :error
      assert AdminConsole.fetch(:"ops ", :feature_flag) == :error
    end

    test "resources/1 lists a live domain's resources and nothing for an unknown key" do
      resources = AdminConsole.resources(:ops)
      keys = Enum.map(resources, & &1.key)
      assert keys == [:feature_flag, :access_rule]
      assert AdminConsole.resources(:nope) == []
    end
  end

  describe "the policy probe (visible?/3)" do
    # Appendix B's probe evidence, pinned: blanket platform-admin
    # policies answer true for the admin and false for anyone else.
    setup do
      admin =
        User.create!(
          "admin-console-admin-#{@n}@fluxvale.com",
          %{platform_role: :admin},
          authorize?: false
        )

      %{admin: admin}
    end

    test "a platform admin may read and create FeatureFlags", %{admin: admin} do
      assert AdminConsole.visible?(admin, FluxVale.Ops.FeatureFlag, :read)
      assert AdminConsole.visible?(admin, FluxVale.Ops.FeatureFlag, :create)
    end

    test "a plain user may not — the route gate is not the policy", %{admin: _admin} do
      user = User.create!("admin-console-user-#{@n}@fluxvale.com", %{}, authorize?: false)

      refute AdminConsole.visible?(user, FluxVale.Ops.FeatureFlag, :read)
      refute AdminConsole.visible?(user, FluxVale.Ops.FeatureFlag, :create)
    end
  end

  describe "the registry-intent gate (allowed_actions/3)" do
    test "a resource's write actions of one type, straight from its definition" do
      creates = AdminConsole.allowed_actions(FluxVale.Ops.FeatureFlag, :create, %{})
      updates = AdminConsole.allowed_actions(FluxVale.Ops.FeatureFlag, :update, %{})
      destroys = AdminConsole.allowed_actions(FluxVale.Ops.AccessRule, :destroy, %{})

      assert Enum.map(creates, & &1.name) == [:create]
      assert Enum.map(updates, & &1.name) == [:update]
      assert Enum.map(destroys, & &1.name) == [:destroy]
    end

    test "the exclusion lists are the machinery-action gate — intent beats policy" do
      # Whatever Ash.can? would say, a registry-excluded action never
      # renders: an excluded :create empties the create set entirely.
      config = %{create_actions: [:create]}

      assert AdminConsole.allowed_actions(FluxVale.Ops.FeatureFlag, :create, config) == []
    end
  end
end

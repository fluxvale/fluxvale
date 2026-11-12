defmodule FluxValeWeb.AdminConsoleTest do
  @moduledoc false

  # The exposure registry's parity discipline (#595): the configured
  # ash_domains partition into live, pending, and excluded-by-name.
  # What is ENFORCED, exactly: every configured domain is accounted
  # for (one of the three sets, no orphans), the six-domain target
  # matches the plan's appendix A, and every LIVE domain's resource
  # set is its registered entries plus its named exclusions, in both
  # directions (the mechanism the audit lane's version tables
  # exercised first, #645; Billing/Topup rides it again in slice 3).
  # Pending domains force nothing per-resource — only their
  # domain-level accounting above. Plus the registry's own API
  # contract: segment resolution and the policy probe.
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

    test "every live domain's resources are included or excluded by name — a new resource forces a decision" do
      for domain <- AdminConsole.domains() do
        registered =
          domain.resources
          |> Enum.map(& &1.module)
          |> MapSet.new()

        actual =
          domain.module
          |> Info.resources()
          |> MapSet.new()

        excluded =
          domain.module
          |> AdminConsole.excluded_resources()
          |> Map.keys()
          |> MapSet.new()

        accounted = MapSet.union(registered, excluded)

        assert MapSet.equal?(accounted, actual),
               "#{inspect(domain.module)}: the registry and the domain disagree on resources — include the new resource or exclude it by name with a reason"

        assert MapSet.disjoint?(registered, excluded),
               "#{inspect(domain.module)}: a resource is both registered and excluded — pick one"
      end
    end

    test "every excluded resource of a live domain carries a documented reason" do
      for domain <- AdminConsole.domains() do
        for {module, reason} <- AdminConsole.excluded_resources(domain.module) do
          assert is_binary(reason) and reason != "",
                 "#{inspect(module)} needs a documented exclusion reason"

          # A stale exclusion (the resource left the domain) would
          # silently narrow the registry — fail it loudly instead.
          assert module in Info.resources(domain.module),
                 "#{inspect(module)} is excluded but no longer a #{inspect(domain.module)} resource"
        end
      end
    end

    test "every exclusion entry names a module its domain actually has — live domain or not" do
      # The liveness arm walks ALL configured domains, pending included:
      # a pending domain's exclusions (the audit lane's version tables
      # ride the map before the domain flips live) go stale just as a
      # live domain's do.
      for domain <- Application.get_env(:flux_vale, :ash_domains) do
        for {module, _reason} <- AdminConsole.excluded_resources(domain) do
          assert module in Info.resources(domain),
                 "#{inspect(module)} is excluded but no longer a #{inspect(domain)} resource — drop the stale exclusion"
        end
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

    test "the Catalog slice's entries resolve" do
      {:ok, entry} = AdminConsole.fetch("catalog", "app")

      assert entry.module == FluxVale.Catalog.App
      assert entry.domain.key == :catalog
      assert entry.config[:label_attr] == :name
    end

    test "fetch_by_module/1 resolves a live registry resource to its entry" do
      {:ok, entry} = AdminConsole.fetch_by_module(FluxVale.Catalog.AppVersion)

      assert entry.key == :app_version
      assert entry.domain.module == FluxVale.Catalog
      assert entry.config[:columns] == [:version, :app_id, :published_at]
    end

    test "the Infrastructure slice's entries resolve" do
      {:ok, entry} = AdminConsole.fetch("infrastructure", "instance")

      assert entry.module == FluxVale.Infrastructure.Instance
      assert entry.domain.key == :infrastructure
      assert entry.config[:label_attr] == :name
      assert entry.config[:status_attrs] == [:status]

      {:ok, by_module} = AdminConsole.fetch_by_module(FluxVale.Infrastructure.Instance)
      assert by_module.key == :instance

      {:ok, snapshot} =
        AdminConsole.fetch_by_module(FluxVale.Infrastructure.InstanceAllocationSnapshot)

      assert snapshot.key == :instance_allocation_snapshot
      assert snapshot.domain.module == FluxVale.Infrastructure
    end

    test "the Infrastructure domain has the nine keys in order" do
      keys =
        :infrastructure
        |> AdminConsole.resources()
        |> Enum.map(& &1.key)

      assert keys == [
               :cluster,
               :instance,
               :instance_allocation_snapshot,
               :backup_setting,
               :backup_run,
               :access_gateway,
               :access_route,
               :access_domain,
               :instance_hostname
             ]
    end

    test "fetch_by_module/1 answers :error for an unregistered module and a pending domain's resource" do
      assert AdminConsole.fetch_by_module(FluxVale.Repo) == :error
      assert AdminConsole.fetch_by_module(FluxVale.Feedback.Post) == :error
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

    # Slice 3's sanity evidence, pinned — MOVED with #657's doctrine:
    # blanket platform-admin authority (the #644 ruling) makes every
    # write answer true for the admin, false for the plain user. The
    # policy layer no longer refuses the admin anything on these
    # resources; the registry's exclusion lists are the sole curation
    # of what the console surfaces (the engine's registry-intent gate,
    # which this suite pins separately in allowed_actions/3).
    test "the Billing sanity probes: blanket authority answers true for the admin, false for users",
         %{admin: admin} do
      user = User.create!("admin-console-billing-#{@n}@fluxvale.com", %{}, authorize?: false)

      # Reads: both actors pass (the member arm scopes a plain user to
      # their own wallets — filter-shaped, maybe_is: true answers yes).
      assert AdminConsole.visible?(admin, FluxVale.Billing.Wallet, :read)
      assert AdminConsole.visible?(user, FluxVale.Billing.Wallet, :read)
      assert AdminConsole.visible?(admin, FluxVale.Billing.LedgerEntry, :read)
      assert AdminConsole.visible?(user, FluxVale.Billing.LedgerEntry, :read)

      # Writes: the doctrine's blanket authority — every action answers
      # true for the admin, false for the plain user. What the console
      # SURFACES is the registry's exclusion lists, pinned separately.
      for action <- [:create, :set_carryover, :set_ladder_state, :set_waiver] do
        assert AdminConsole.visible?(admin, FluxVale.Billing.Wallet, action)
        refute AdminConsole.visible?(user, FluxVale.Billing.Wallet, action)
      end

      for action <- [:create, :grant_goodwill, :reverse] do
        assert AdminConsole.visible?(admin, FluxVale.Billing.LedgerEntry, action)
        refute AdminConsole.visible?(user, FluxVale.Billing.LedgerEntry, action)
      end
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

    test "the Billing configs curate the operator set (slice 3's registry intent)" do
      {:ok, wallet} = AdminConsole.fetch(:billing, :wallet)
      {:ok, ledger} = AdminConsole.fetch(:billing, :ledger_entry)

      # Wallet: read plus set_waiver — creates and ladder state are
      # system-only, excluded by name.
      assert names(AdminConsole.allowed_actions(wallet.module, :create, wallet.config)) == []

      assert names(AdminConsole.allowed_actions(wallet.module, :update, wallet.config)) == [
               :set_waiver
             ]

      assert names(AdminConsole.allowed_actions(wallet.module, :destroy, wallet.config)) == []

      # Ledger: goodwill only — the system create and the curated
      # surface's reverse never render here.
      assert names(AdminConsole.allowed_actions(ledger.module, :create, ledger.config)) == [
               :grant_goodwill
             ]

      assert names(AdminConsole.allowed_actions(ledger.module, :update, ledger.config)) == []
      assert names(AdminConsole.allowed_actions(ledger.module, :destroy, ledger.config)) == []
    end

    test "the Infrastructure configs curate the operator set (slice 5's registry intent)" do
      {:ok, instance} = AdminConsole.fetch(:infrastructure, :instance)

      instance_updates =
        instance.module
        |> AdminConsole.allowed_actions(:update, instance.config)
        |> names()

      refute :perform_deploy in instance_updates
      refute :perform_reconcile in instance_updates
      refute :settle_anchors in instance_updates
      assert :set_exposure in instance_updates
      assert :grow_storage in instance_updates

      table = [
        {:instance_allocation_snapshot, :create, []},
        {:instance_allocation_snapshot, :update, []},
        {:access_route, :destroy, []},
        {:access_gateway, :destroy, []},
        {:access_domain, :create, [:register]},
        {:instance_hostname, :create, []},
        {:backup_run, :update, []}
      ]

      for {key, type, expected} <- table do
        {:ok, entry} = AdminConsole.fetch(:infrastructure, key)

        assert names(AdminConsole.allowed_actions(entry.module, type, entry.config)) == expected,
               "#{inspect(key)} #{type} drifted from the registry's intent list"
      end
    end

    test "Topup is excluded by name with its documented reason" do
      excluded = AdminConsole.excluded_resources(FluxVale.Billing)

      assert Map.has_key?(excluded, FluxVale.Billing.Topup)
      assert excluded[FluxVale.Billing.Topup] =~ "gateway"

      # The version tables ride the same exclusion arm on every live
      # domain (#645): Billing, Pricing, Catalog, and Feedback join Ops
      # as their slices land.
      ops = AdminConsole.excluded_resources(FluxVale.Ops)
      assert Map.has_key?(ops, FluxVale.Ops.FeatureFlag.Version)

      pricing = AdminConsole.excluded_resources(FluxVale.Pricing)
      assert Map.has_key?(pricing, FluxVale.Pricing.Size.Version)
      assert Map.has_key?(pricing, FluxVale.Pricing.TaxRate.Version)

      catalog = AdminConsole.excluded_resources(FluxVale.Catalog)
      assert Map.has_key?(catalog, FluxVale.Catalog.App.Version)

      feedback = AdminConsole.excluded_resources(FluxVale.Feedback)
      assert Map.has_key?(feedback, FluxVale.Feedback.Post.Version)

      # a domain with no exclusions answers empty, unknown or not.
      assert AdminConsole.excluded_resources(FluxVale.Nowhere) == %{}
    end
  end

  defp names(actions), do: Enum.map(actions, & &1.name)
end

defmodule FluxVale.AdminAuthorityTest do
  @moduledoc false

  # The doctrine gate (#644, ADR-0047): every resource of every
  # configured domain is in exactly ONE of three states — full (the
  # condition-pair bypass AND the paper-trail block), machinery-exempt
  # (by name, with a reason), or trail-pending (the bypass is live, the
  # trail arrives with the named rollout slice). Anything else fails
  # the build: the doctrine survives resource growth — a new resource
  # joins a set deliberately or CI is red, never silently.
  #
  # The set table is the authority (the plan's shared business-set
  # table); this gate is its forcing function, the same shape as the
  # console registry's parity test. The arms walk compiled modules —
  # no DB needed.

  use FluxVale.DataCase, async: true

  alias Ash.Domain.Info
  alias Spark.Dsl.Extension

  # The doctrine bypass's exact condition pair (ADR-0047): the existing
  # platform-admin check AND the call-origin refusal that keeps the
  # blanket off every PAT.
  @pair MapSet.new([FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi])

  # The plan's 31-resource business set — both arcs act on this list.
  @business_set MapSet.new([
                  # Ops
                  FluxVale.Ops.FeatureFlag,
                  FluxVale.Ops.AccessRule,
                  # Catalog
                  FluxVale.Catalog.Category,
                  FluxVale.Catalog.App,
                  FluxVale.Catalog.AppVersion,
                  # Infrastructure
                  FluxVale.Infrastructure.Cluster,
                  FluxVale.Infrastructure.Instance,
                  FluxVale.Infrastructure.BackupSetting,
                  FluxVale.Infrastructure.BackupRun,
                  FluxVale.Infrastructure.AccessGateway,
                  FluxVale.Infrastructure.AccessRoute,
                  FluxVale.Infrastructure.AccessDomain,
                  FluxVale.Infrastructure.InstanceHostname,
                  FluxVale.Infrastructure.PocketIdCustody,
                  FluxVale.Infrastructure.StorageRequest,
                  # Pricing
                  FluxVale.Pricing.Size,
                  FluxVale.Pricing.TaxRate,
                  # Billing
                  FluxVale.Billing.Wallet,
                  FluxVale.Billing.LedgerEntry,
                  FluxVale.Billing.Topup,
                  # Feedback
                  FluxVale.Feedback.Post,
                  FluxVale.Feedback.Vote,
                  FluxVale.Feedback.Comment,
                  FluxVale.Feedback.Tag,
                  FluxVale.Feedback.PostTag,
                  # Identity
                  FluxVale.Identity.User,
                  FluxVale.Identity.UserEmail,
                  FluxVale.Identity.PersonalAccessToken,
                  # Accounts
                  FluxVale.Accounts.Organization,
                  FluxVale.Accounts.Membership,
                  FluxVale.Accounts.MembershipInvite
                ])

  # Machinery by name, each with its reason — the plan's seven rows
  # (the Nov 9 amendment added PocketIdCustodyEvent), plus every
  # generated version resource (the audit surface itself: two Ops rows,
  # then the A2-S2 domains' thirteen). Extending this map is the
  # deliberate act the gate forces.
  @exempt %{
    FluxVale.Infrastructure.InstanceAllocationSnapshot =>
      "append-only telemetry — the table IS its trail",
    FluxVale.Identity.Token =>
      "ephemeral auth machinery: secret-adjacent, AshAuthentication owns it",
    FluxVale.Identity.AuthCode =>
      "ephemeral auth machinery: minutes-to-days lifetime, secret-adjacent",
    FluxVale.Identity.DeviceCode =>
      "ephemeral auth machinery: device-flow state, AshAuthentication owns it",
    FluxVale.Api.AuditEvent =>
      "itself the machine-API audit — versioning it is a trail of a trail",
    FluxVale.Api.RequestWindow => "janitor bookkeeping",
    FluxVale.Infrastructure.PocketIdCustodyEvent =>
      "append-only custody history — its own table IS its trail, the InstanceAllocationSnapshot stance",
    FluxVale.Billing.Wallet.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Billing.LedgerEntry.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Billing.Topup.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Pricing.Size.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Pricing.TaxRate.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Catalog.Category.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Catalog.App.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Catalog.AppVersion.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Feedback.Post.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Feedback.Vote.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Feedback.Comment.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Feedback.Tag.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Feedback.PostTag.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Ops.FeatureFlag.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Ops.AccessRule.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.Cluster.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.Instance.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.BackupSetting.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.BackupRun.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.AccessGateway.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.AccessRoute.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.AccessDomain.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.InstanceHostname.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.PocketIdCustody.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Infrastructure.StorageRequest.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Identity.User.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Identity.UserEmail.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Identity.PersonalAccessToken.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Accounts.Organization.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Accounts.Membership.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed",
    FluxVale.Accounts.MembershipInvite.Version =>
      "generated version resource (ADR-0048): the audit surface itself, never audited or blanket-governed"
  }

  # Trail pendings: the bypass is live, the paper trail arrives with
  # the named A2 rollout slice. A2-S3 emptied this map — the business
  # set is fully trailed (the doctrine's zero-pendings state, ahead of
  # the A2-S4 console slice).
  @pending %{}

  describe "the states account for every configured resource" do
    test "every walked resource is business-set or exempt — and every entry is real" do
      walked = walked_resources()

      exempt =
        @exempt
        |> Map.keys()
        |> MapSet.new()

      accounted = MapSet.union(@business_set, exempt)

      assert MapSet.equal?(walked, accounted),
             "undecided resource(s): #{inspect(MapSet.to_list(MapSet.difference(walked, accounted)))} — " <>
               "join the business set, or add a named exemption entry with its reason"
    end

    test "no stale entries — the gate narrows with the domain, never rots" do
      walked = walked_resources()

      for module <- MapSet.to_list(@business_set) do
        assert module in walked,
               "#{inspect(module)} left the domain — drop it from the business set"
      end

      for module <- Map.keys(@exempt) do
        assert module in walked, "#{inspect(module)} is exempt but no longer a resource"
      end

      for module <- Map.keys(@pending) do
        assert module in walked, "#{inspect(module)} is pending but no longer a resource"
      end
    end

    test "pending rides inside the business set; exemptions sit outside it" do
      exempt =
        @exempt
        |> Map.keys()
        |> MapSet.new()

      pending =
        @pending
        |> Map.keys()
        |> MapSet.new()

      assert MapSet.disjoint?(@business_set, exempt)
      assert MapSet.subset?(pending, @business_set)
    end

    # The phasing's printed partition (the rollout slices flip it slice
    # by slice): a moved count is a deliberate diff to this line, the
    # same forcing function as the sets themselves. A2-S3's landing
    # state: full 31, exempt 38 (7 machinery + 31 version resources),
    # pending 0 — the business set is fully trailed.
    test "the partition counts: full 31, exempt 38, pending 0" do
      pending =
        @pending
        |> Map.keys()
        |> MapSet.new()

      full = MapSet.difference(@business_set, pending)

      assert MapSet.size(full) == 31,
             "the full set moved to #{MapSet.size(full)} — expected 31: a rollout slice landed, update this count"

      assert map_size(@exempt) == 38,
             "the exempt set moved to #{map_size(@exempt)} — expected 38: 7 machinery rows plus 31 generated version resources"

      assert MapSet.size(pending) == 0,
             "the pending set moved to #{MapSet.size(pending)} — expected 0: the business set is fully trailed, a new resource joins a set deliberately"
    end
  end

  describe "full — bypass AND paper trail (the closing state)" do
    test "every business-set resource carries the condition-pair bypass" do
      for resource <- MapSet.to_list(@business_set) do
        assert doctrine_bypass?(resource),
               "#{inspect(resource)} lacks the condition-pair bypass (#644, ADR-0047)"
      end
    end

    test "full resources carry both halves; pendings carry exactly the bypass" do
      # The pending-state machinery stays despite the empty map: a
      # future resource may arrive ahead of its trail (the A2 slices'
      # shape), and the gate must carry that again. The map_size guard
      # keeps the branch live-typed at zero instead of statically dead.
      for resource <- MapSet.to_list(@business_set) do
        trailed? = trailed?(resource)

        pending_slice = map_size(@pending) > 0 && Map.get(@pending, resource)

        if is_binary(pending_slice) do
          refute trailed?,
                 "#{inspect(resource)} is pending but the trail already landed — promote it to full"

          assert pending_slice in ~w(A2-S2 A2-S3),
                 "#{inspect(resource)} names an unknown resolving slice"
        else
          assert trailed?,
                 "#{inspect(resource)} is neither full nor pending — the trail half decides which"
        end
      end
    end

    test "every full resource's Version module is registered in its domain" do
      full = full_resources()

      assert length(full) == 31,
             "the full set moved to #{length(full)} — expected 31: a rollout slice landed, update the phasing counts"

      for resource <- full do
        domain = domain_of(resource)

        assert AshPaperTrail.Resource.Info.version_resource(resource) in Info.resources(domain),
               "#{inspect(resource)} is full but its Version module is not registered in " <>
                 "#{inspect(domain)} — include_versions? is not riding the domain"
      end
    end

    test "every full resource's trail options match the posture (ADR-0048)" do
      for resource <- full_resources() do
        assert AshPaperTrail.Resource.Info.mixin(resource) ==
                 {FluxVale.PaperTrail.VersionMixin, :version_resource, []},
               "#{inspect(resource)} carries the wrong mixin — one config posture, the mixin is mandatory"

        refute AshPaperTrail.Resource.Info.reference_source?(resource),
               "#{inspect(resource)} references its source — destroy evidence must outlive the record"

        assert AshPaperTrail.Resource.Info.change_tracking_mode(resource) == :changes_only,
               "#{inspect(resource)} left changes_only — the compact atomic-safe mode is doctrine"

        assert AshPaperTrail.Resource.Info.sensitive_attributes(resource) == :redact,
               "#{inspect(resource)} un-redacted — the blanket sensitive posture is doctrine"
      end
    end
  end

  describe "exempt — by name, with a reason" do
    test "every exemption names a reason" do
      for {module, reason} <- @exempt do
        assert is_binary(reason) and reason != "",
               "#{inspect(module)} needs a documented exemption reason"
      end
    end
  end

  # The walked universe: every resource of every configured domain.
  defp walked_resources do
    :flux_vale
    |> Application.get_env(:ash_domains)
    |> Enum.flat_map(&Info.resources/1)
    |> MapSet.new()
  end

  # The full set: business-set resources whose trail has landed (the
  # complement of the pendings).
  defp full_resources do
    pending =
      @pending
      |> Map.keys()
      |> MapSet.new()

    @business_set
    |> MapSet.difference(pending)
    |> MapSet.to_list()
  end

  # The configured domain carrying the resource — nil would mean the
  # gate's walked universe and the config disagree, which the first
  # test already refuses.
  defp domain_of(resource) do
    domains = Application.get_env(:flux_vale, :ash_domains)

    domain = Enum.find(domains, fn domain -> resource in Info.resources(domain) end)

    domain || raise("#{inspect(resource)} is in no configured domain")
  end

  # Whether the paper-trail extension rides the resource at all. NOT
  # `PaperTrailInfo.version_resource?/1`: that helper answers the MODE
  # question and defaults to :version_resource for resources that never
  # used the extension — every un-trailed resource would read true.
  defp trailed?(resource) do
    extensions = Extension.get_persisted(resource, :extensions)
    AshPaperTrail.Resource in extensions
  end

  # A bypass policy whose condition is EXACTLY the doctrine pair — the
  # actor check plus the call-origin refusal, nothing narrower.
  defp doctrine_bypass?(resource) do
    resource
    |> Ash.Policy.Info.policies()
    |> Enum.any?(fn policy ->
      policy.bypass? and condition_is_pair?(policy.condition)
    end)
  end

  defp condition_is_pair?(condition) do
    checks = MapSet.new(condition, fn {module, _opts} -> module end)
    MapSet.equal?(checks, @pair)
  end
end

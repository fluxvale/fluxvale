defmodule FluxVale.Infrastructure.Operations.InstanceK8sTest do
  # NOT async: the fail-loud arms mutate the :access_gateway application
  # env, which is global. It is restored in on_exit.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  # The provider seam must raise BEFORE its first write, not after the
  # route row lands: the cleanup clauses only handle error tuples, and
  # an idempotent retry would then report {:ok, existing} with no
  # cluster limb ever written (hostile review, fix round).
  test "attach raises on a missing namespace BEFORE the route row lands" do
    InstanceFixtures.local_cluster!()

    # Fixture scaffolding only: the provider raises before any cluster
    # limb, so nothing below the resolver is ever reached.
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)
    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)

    Application.put_env(:flux_vale, :access_gateway, image: "tailscale/tailscale:v1.90.6")

    assert_raise KeyError, ~r/key :namespace not found/, fn ->
      Tailscale.attach_instance(gateway, instance)
    end

    assert {:error, _no_route} =
             AccessRoute.get_by_instance(instance.id, authorize?: false)
  end

  setup do
    original = Application.fetch_env(:flux_vale, :access_gateway)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore({:ok, value}), do: Application.put_env(:flux_vale, :access_gateway, value)
  defp restore(:error), do: Application.delete_env(:flux_vale, :access_gateway)

  describe "gateway_access_namespace/0" do
    test "returns the configured namespace" do
      Application.put_env(:flux_vale, :access_gateway, namespace: "fluxvale-access")

      assert InstanceK8s.gateway_access_namespace() == "fluxvale-access"
    end

    test "the config value wins — no hardcoded fallback" do
      Application.put_env(:flux_vale, :access_gateway, namespace: "a-different-ns")

      assert InstanceK8s.gateway_access_namespace() == "a-different-ns"
    end

    test "raises rather than admitting into a default when the key is missing" do
      # Carried finding #1: a silent "fluxvale-access" fallback admitted the
      # peer into one namespace while the Deployment went elsewhere, so
      # every reconfigure severed reachability. Fail loudly instead.
      Application.put_env(:flux_vale, :access_gateway, image: "tailscale/tailscale:v1.90.6")

      assert_raise KeyError, ~r/key :namespace not found/, fn ->
        InstanceK8s.gateway_access_namespace()
      end
    end

    test "a nil or empty namespace VALUE fails as loudly as a missing key" do
      # An env-var interpolation that yields nil is one deploy away;
      # fetch!/2 alone would happily return it.
      for value <- [nil, ""] do
        Application.put_env(:flux_vale, :access_gateway, namespace: value)

        assert_raise CaseClauseError, fn ->
          InstanceK8s.gateway_access_namespace()
        end
      end
    end

    test "raises when the config block is absent entirely" do
      # A missing block is ArgumentError from fetch_env!/2; a missing key
      # inside a block is KeyError. Both fail loudly — neither falls back.
      Application.delete_env(:flux_vale, :access_gateway)

      assert_raise ArgumentError, ~r/:access_gateway/, fn ->
        InstanceK8s.gateway_access_namespace()
      end
    end
  end

  describe "update_status/4 truncation" do
    test "a multi-codepoint-grapheme message past the 500-codepoint cap truncates and still writes" do
      # The never-fails-the-write invariant (hostile review, fix round):
      # status_message validates at 500 codepoints, and every grapheme
      # here is TWO codepoints. 300 graphemes carry 600 codepoints, so a
      # grapheme-based cut would leave the whole string intact and fail
      # the write. The codepoint cut lands inside the cap instead.
      InstanceFixtures.local_cluster!()

      version = InstanceFixtures.app_version!()

      user =
        User.create!("k8s-truncate-#{System.unique_integer()}@fluxvale.com", %{},
          authorize?: false
        )

      instance = InstanceFixtures.instance!(version, user)
      message = String.duplicate("a" <> "\u0301", 300)

      assert String.length(message) == 300
      assert length(String.codepoints(message)) == 600

      assert {:ok, updated} = InstanceK8s.update_status(instance, :deploying, message)

      assert length(String.codepoints(updated.status_message)) == 500
      assert String.length(updated.status_message) == 250
    end
  end

  # #612 (ADR-0045, D1): the DB requests are carved FROM the purchased
  # allocation — the app container shrinks by the services' shares, the
  # pod's total requests stay exactly the allocation, and the quota is
  # untouched by backing services (they are purchased workload, not
  # platform overhead — the file-access sidecar's counter-posture).
  describe "deployment_spec/2 + quota_spec/1 — the backing carve" do
    defp backing_instance!(attrs \\ []) do
      version_opts =
        attrs
        |> Keyword.get(:version_opts, [])
        |> Map.new()

      instance_attrs =
        attrs
        |> Keyword.delete(:version_opts)
        |> Map.new()

      version = InstanceFixtures.backing_version!(version_opts)
      InstanceFixtures.local_cluster!()

      base = %{name: "Carved", app_version_id: version.id, env_vars: %{}}
      params = Map.merge(base, instance_attrs)

      Instance.create!(params, actor: carve_user())
    end

    defp carve_user do
      User.create!("carve-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
    end

    test "app requests = allocation − shares; pod total = allocation exactly (Decimal)" do
      instance = backing_instance!()

      spec = InstanceK8s.deployment_spec(instance, %{})

      # The fixture's honest defaults: 1.0 CPU / 1024 MB; the launch
      # shares carve PG 0.10/256 + Redis 0.05/64.
      assert Decimal.eq?(spec.cpu, Decimal.new("0.85"))
      assert spec.memory == 704

      [pg, redis] = spec.backing_services
      assert pg.cpu == Decimal.new("0.10") and pg.memory_mb == 256
      assert redis.cpu == Decimal.new("0.05") and redis.memory_mb == 64
      assert pg.image == "postgres:18.6-alpine3.24"
      assert redis.image == "redis:8.10.3-alpine3.23"
      assert pg.env_from_secret == "backing-services"
      assert redis.env_from_secret == "backing-services"

      pod_cpu =
        Enum.reduce([spec.cpu | Enum.map(spec.backing_services, & &1.cpu)], &Decimal.add/2)

      assert Decimal.eq?(pod_cpu, instance.cpu_cores)

      pod_memory =
        Enum.sum([spec.memory | Enum.map(spec.backing_services, & &1.memory_mb)])

      assert pod_memory == instance.memory_mb
    end

    test "a postgres-only instance carves only postgres" do
      instance =
        backing_instance!(
          version_opts: [
            backing_services: [
              %{"kind" => "postgres", "version" => "18", "url_env" => "DATABASE_URL"}
            ]
          ]
        )

      spec = InstanceK8s.deployment_spec(instance, %{})

      assert Decimal.eq?(spec.cpu, Decimal.new("0.9"))
      assert spec.memory == 768
      assert [%{kind: :postgres}] = spec.backing_services
    end

    test "quota_spec stays the bare allocation — carved, never widened" do
      instance = backing_instance!()

      assert {:ok, quota} = InstanceK8s.quota_spec(instance)
      assert Decimal.eq?(quota.cpu, Decimal.new("1"))
      assert quota.memory == 1024
      assert quota.storage == 10
    end

    test "the file-access sidecar stays additive on top of the carve (both postures compose)" do
      instance =
        backing_instance!(
          version_opts: [file_access: true],
          # The wizard's legal floor for a file-access app is a volume;
          # the carve arithmetic is the point here.
          storage_gb: 10
        )

      spec = InstanceK8s.deployment_spec(instance, %{})

      # App: allocation − DB shares. Sidecar: platform overhead on TOP
      # (its own posture, unchanged). Quota: allocation + sidecar.
      assert Decimal.eq?(spec.cpu, Decimal.new("0.85"))
      assert spec.sidecar.cpu == Decimal.new("0.05")

      assert {:ok, quota} = InstanceK8s.quota_spec(instance)
      assert Decimal.eq?(quota.cpu, Decimal.new("1.05"))

      pod_cpu =
        Enum.reduce(
          [spec.cpu, spec.sidecar.cpu | Enum.map(spec.backing_services, & &1.cpu)],
          &Decimal.add/2
        )

      assert Decimal.eq?(pod_cpu, quota.cpu)
    end

    test "a non-declaring instance keeps the plain spec (no backing key)" do
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      instance = InstanceFixtures.instance!(version, carve_user())

      spec = InstanceK8s.deployment_spec(instance, %{})

      refute Map.has_key?(spec, :backing_services)
      assert Decimal.eq?(spec.cpu, version.default_cpu_cores)
      assert spec.memory == version.default_memory_mb
    end
  end
end

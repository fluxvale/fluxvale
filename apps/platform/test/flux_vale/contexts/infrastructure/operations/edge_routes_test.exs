defmodule FluxVale.Infrastructure.Operations.EdgeRoutesTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  # Pure manifest-shape tests (#203, ADR-0036): the two modes are the
  # sleep/wake contract — what Traefik routes to decides whether a
  # sleeping instance wakes and a woken one serves. The k8s applies
  # are stubbed; the specs are the assertion surface.

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("edge-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp instance!(version_opts, create_opts \\ %{}) do
    version = InstanceFixtures.app_version!(version_opts)
    InstanceFixtures.local_cluster!()

    defaults = %{name: "App", app_version_id: version.id, env_vars: %{}, storage_gb: 10}
    params = Map.merge(defaults, Map.new(create_opts))

    instance = Instance.create!(params, actor: user())

    InstanceFixtures.pin!(instance,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  describe "apply_serving/2" do
    test "app route targets the app Service with the beacon attached" do
      stub_kubeconfig()
      instance = instance!(%{})

      expect(Middleware, :create, fn _kc, _ns, "fluxvale-activity", spec ->
        address = spec.forward_auth.address

        assert address =~ "/internal/edge/touch?instance=#{instance.id}"
        assert address =~ "fluxvale-platform.fluxvale-dev.svc.cluster.local:4000"
        # Without the UA forward, probes couldn't be filtered.
        assert spec.forward_auth.auth_request_headers == ["User-Agent"]
        {:ok, %{}}
      end)

      expect(Ingress, :create, fn _kc, _ns, "app-ingress", spec ->
        assert spec.service_name == "app"
        assert spec.service_port == 80
        assert spec.subdomain == instance.slug
        assert spec.tls
        assert spec.middlewares == ["fluxvale-activity"]
        refute Map.has_key?(spec, :path_prefix)
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_serving(%{}, instance)
    end

    test "file-access instances get the /dav serving route too" do
      stub_kubeconfig()
      instance = instance!(%{file_access: true})

      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      # Mimic expects outrank stubs: one expect answers both routes.
      expect(Ingress, :create, 2, fn
        _kc, _ns, "app-ingress", _spec ->
          {:ok, %{}}

        _kc, _ns, "app-dav", spec ->
          assert spec.service_name == "dav"
          assert spec.path_prefix == "/dav"
          assert spec.middlewares == ["fluxvale-activity"]
          {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_serving(%{}, instance)
    end
  end

  describe "apply_wake/2" do
    test "wake route targets the platform via the namespace's wake Service" do
      stub_kubeconfig()
      instance = instance!(%{})

      expect(Service, :create, fn _kc, _ns, "wake", spec ->
        assert spec.external_name == "fluxvale-platform.fluxvale-dev.svc.cluster.local"
        assert spec.port == 4000
        {:ok, %{}}
      end)

      expect(Middleware, :create, fn _kc, _ns, "fluxvale-wake", spec ->
        assert spec.request_headers == %{"X-FluxVale-Instance" => instance.id}
        {:ok, %{}}
      end)

      expect(Ingress, :create, fn _kc, _ns, "app-ingress", spec ->
        assert spec.service_name == "wake"
        assert spec.middlewares == ["fluxvale-wake"]
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_wake(%{}, instance)
    end

    test "the dav route flips to wake mode with its path prefix kept" do
      stub_kubeconfig()
      instance = instance!(%{file_access: true})

      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Ingress, :create, 2, fn
        _kc, _ns, "app-ingress", _spec ->
          {:ok, %{}}

        _kc, _ns, "app-dav", spec ->
          assert spec.service_name == "wake"
          assert spec.path_prefix == "/dav"
          assert spec.middlewares == ["fluxvale-wake"]
          {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_wake(%{}, instance)
    end

    test "no dav route is minted for a volume-less file-access instance" do
      stub_kubeconfig()
      instance = instance!(%{file_access: true}, storage_gb: 0)

      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      # The dav route must never exist: reaching for it fails the test.
      stub(Ingress, :create, fn
        _kc, _ns, "app-ingress", _spec -> {:ok, %{}}
        _kc, _ns, "app-dav", _spec -> flunk("no dav route for a volume-less instance")
      end)

      assert :ok = EdgeRoutes.apply_wake(%{}, instance)
    end

    test "a dav apply failure propagates instead of half-flipping" do
      stub_kubeconfig()
      instance = instance!(%{file_access: true})

      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      # One stub answers both routes — Mimic expects outrank stubs,
      # so the app-ingress clause must live here too.
      stub(Ingress, :create, fn
        _kc, _ns, "app-ingress", _spec ->
          {:ok, %{}}

        _kc, _ns, "app-dav", _spec ->
          {:error, Error.connection_error("routes refused")}
      end)

      assert {:error, _error} = EdgeRoutes.apply_wake(%{}, instance)
    end
  end

  describe "ensure_wake_targets/2" do
    test "applies the wake Service and marker without touching routes" do
      stub_kubeconfig()
      instance = instance!(%{})

      expect(Service, :create, fn _kc, _ns, "wake", spec ->
        assert spec.external_name
        {:ok, %{}}
      end)

      expect(Middleware, :create, fn _kc, _ns, "fluxvale-wake", _spec -> {:ok, %{}} end)

      # The routes are NOT this call's business.
      reject(Ingress, :create, 4)

      assert :ok = EdgeRoutes.ensure_wake_targets(%{}, instance)
    end
  end

  describe "instance_header/0" do
    test "is the one header name — the marker mints it, the endpoint reads it" do
      assert EdgeRoutes.instance_header() == "X-FluxVale-Instance"
    end
  end
end

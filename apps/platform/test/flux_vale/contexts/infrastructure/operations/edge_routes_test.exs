defmodule FluxVale.Infrastructure.Operations.EdgeRoutesTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  # Pure manifest-shape tests (#203, ADR-0036): the two modes are the
  # sleep/wake contract — what Traefik routes to decides whether a
  # sleeping instance wakes and a woken one serves. The k8s applies
  # are stubbed; the specs are the assertion surface.

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  defp user do
    User.create!("edge-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp instance!(version_opts, create_opts \\ %{}, actor \\ nil) do
    version = InstanceFixtures.app_version!(version_opts)
    InstanceFixtures.local_cluster!()

    defaults = %{name: "App", app_version_id: version.id, env_vars: %{}, storage_gb: 10}
    params = Map.merge(defaults, Map.new(create_opts))

    instance = Instance.create!(params, actor: actor || user())

    InstanceFixtures.pin!(instance,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  # -----------------------------------------------------------------
  # The access arms (ADR-0040 §7). The gateway is passed as a bare map:
  # the arms read only its id (the pair in the wake path).
  # -----------------------------------------------------------------

  defp gateway_stub, do: %{id: Ash.UUID.generate()}

  defp hostname!(instance_id) do
    InstanceHostname
    |> Ash.Query.filter(instance_id == ^instance_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp hostname_host!(instance_id) do
    hostname = hostname!(instance_id)

    %{
      hostname
      | access_domain: Ash.load!(hostname, :access_domain, authorize?: false).access_domain
    }
  end

  # A custom domain row under `owner`'s org. `verified?: true` walks the
  # verify pass's own funnel (the ref is what the observer recorded —
  # and the source read the arms' cert replica will do).
  defp custom_domain!(owner, opts \\ []) do
    {:ok, registered} =
      AccessDomain.register(
        %{domain: "apps.customer-#{System.unique_integer()}.example"},
        actor: owner
      )

    if Keyword.get(opts, :verified?, false) do
      registered
      |> Ash.Changeset.for_update(:mark_verified, %{cert_secret_ref: "custom-wildcard-tls"},
        authorize?: false
      )
      |> Ash.update!()
    else
      registered
    end
  end

  # A custom domain + hostname row under it.
  defp custom_hostname!(owner, instance, label, opts \\ []) do
    domain = custom_domain!(owner, opts)

    # S1's system-only mint (the edge arms read rows, never mint them).
    InstanceHostname.mint!(
      %{instance_id: instance.id, access_domain_id: domain.id, label: label},
      authorize?: false
    )
  end

  defp stub_access_targets(ns) do
    stub(Service, :create, fn _kc, ^ns, "wake", _spec -> {:ok, %{}} end)

    stub(Middleware, :create, fn
      _kc, ^ns, "fluxvale-access-wake", _spec -> {:ok, %{}}
      _kc, ^ns, "fluxvale-activity", _spec -> {:ok, %{}}
    end)
  end

  # The cert replica's source: the fleet's cert-manager writes the
  # issued wildcard here (:access_domains, :certificate_namespace).
  defp stub_cert_source do
    stub(Secret, :get_data, fn _kc, "fluxvale-access", "custom-wildcard-tls" ->
      {:ok, %{"tls.crt" => "CERT-PEM", "tls.key" => "KEY-PEM"}}
    end)

    stub(Secret, :create, fn _kc, _ns, "access-domain-cert-" <> _tail, _data, _labels ->
      {:ok, %{}}
    end)
  end

  defp stub_middleware_delete(ns) do
    stub(Middleware, :delete, fn _kc, ^ns, "fluxvale-access-wake" ->
      {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
    end)
  end

  describe "apply_access_serving/3 (ADR-0040 §7)" do
    test "one host-keyed route per hostname row — access entrypoint, app target, beacon" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"
      hostname = hostname_host!(instance.id)

      # The dormant wake targets ride along (#203: pre-created, so the
      # first sleep only rewrites routes Traefik already watches) — and
      # the beacon lands first (the public serving arm's order).
      expect(Service, :create, fn _kc, ^ns, "wake", spec ->
        assert spec.external_name == "fluxvale-platform.fluxvale-dev.svc.cluster.local"
        {:ok, %{}}
      end)

      expect(Middleware, :create, 2, fn
        _kc, ^ns, "fluxvale-access-wake", _spec -> {:ok, %{}}
        _kc, ^ns, "fluxvale-activity", _spec -> {:ok, %{}}
      end)

      expect(Ingress, :create, fn _kc, ^ns, "access-" <> _tail, spec ->
        assert spec.host == "#{hostname.label}.#{hostname.access_domain.domain}"
        # The entrypoint is a NAME — the platform never knows a port.
        assert spec.entrypoint == "access"
        assert spec.service_name == "app"
        assert spec.service_port == 80
        assert spec.middlewares == ["fluxvale-activity"]
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_access_serving(%{}, gateway_stub(), instance)
    end

    test "a platform domain rides the default TLSStore — tls: true, NO secretName" do
      stub_kubeconfig()
      instance = instance!(%{})
      stub_access_targets("fluxvale-app-#{instance.id}")

      expect(Ingress, :create, fn _kc, _ns, _name, spec ->
        assert spec.tls
        refute Map.has_key?(spec, :tls_secret_name)
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_access_serving(%{}, gateway_stub(), instance)
    end

    test "a verified custom domain routes with its LOCAL cert replica; an unverified one never routes" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = custom_domain!(owner, verified?: true)

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: domain.id, label: "wiki"},
        authorize?: false
      )

      dark = custom_domain!(owner)

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: dark.id, label: "dark"},
        authorize?: false
      )

      stub_access_targets(ns)
      stub_cert_source()

      parent = self()

      stub(Secret, :create, fn _kc, ^ns, "access-domain-cert-" <> _tail, data, labels ->
        send(parent, {:replica, data, labels})
        {:ok, %{}}
      end)

      stub(Ingress, :create, fn
        _kc, ^ns, _name, %{host: "wiki." <> _tail} = spec ->
          send(parent, {:custom_route, spec})
          {:ok, %{}}

        _kc, ^ns, _name, %{host: "dark." <> _tail} ->
          send(parent, {:dark_route, "routed!"})
          {:ok, %{}}

        _kc, ^ns, _name, _spec ->
          # The default platform hostname — an ordinary mint.
          {:ok, %{}}
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_access_serving(%{}, gateway_stub(), instance)
        end)

      assert_received {:replica, data, labels}
      assert data == %{"tls.crt" => "CERT-PEM", "tls.key" => "KEY-PEM"}
      assert labels["fluxvale.io/access-domain"] == domain.id

      assert_received {:custom_route, spec}
      assert spec.tls
      # The route references the LOCAL replica, never the cross-namespace
      # source (Traefik's CRD provider reads the route's own namespace).
      assert spec.tls_secret_name =~ ~r/^access-domain-cert-[0-9a-f]{10}$/

      # The unverified row was skipped with the reason logged — an
      # unverified domain must never route.
      refute_received {:dark_route, _}
      assert log =~ "custom domain apps.customer-"
      assert log =~ "not servable"
    end

    test "a custom domain whose source secret is unreadable is skipped — never a dead cert" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)

      domain = custom_domain!(owner, verified?: true)

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: domain.id, label: "wiki"},
        authorize?: false
      )

      stub_access_targets("fluxvale-app-#{instance.id}")

      stub(Secret, :get_data, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(Ingress, :create, fn
        _kc, _ns, _name, %{host: "wiki." <> _tail} ->
          flunk("an unreadable cert source must never route")

        _kc, _ns, _name, _spec ->
          # The default platform hostname still mints — the skip is the
          # domain's, not the arm's.
          {:ok, %{}}
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_access_serving(%{}, gateway_stub(), instance)
        end)

      assert log =~ "certificate secret could not be replicated"
      assert log =~ "never routing a dead cert"
    end

    test "a hostname under another org's domain never routes (the S3 belt)" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)

      # The domain belongs to a DIFFERENT org entirely — a row shaped
      # like this is out-of-band today (S3's re-homing surface); the
      # belt refuses it safely.
      foreign_domain = custom_domain!(user())

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: foreign_domain.id, label: "foreign"},
        authorize?: false
      )

      stub_access_targets("fluxvale-app-#{instance.id}")

      stub(Ingress, :create, fn
        _kc, _ns, _name, %{host: "foreign." <> _tail} ->
          flunk("a foreign-org hostname must never route")

        _kc, _ns, _name, _spec ->
          {:ok, %{}}
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_access_serving(%{}, gateway_stub(), instance)
        end)

      assert log =~ "another organization"
    end

    test "ensure_access_cert_secret replicates the source into the instance namespace" do
      stub_kubeconfig()
      owner = user()
      domain = custom_domain!(owner, verified?: true)

      parent = self()

      stub(Secret, :get_data, fn _kc, "fluxvale-access", "custom-wildcard-tls" ->
        {:ok, %{"tls.crt" => "CERT-PEM", "tls.key" => "KEY-PEM"}}
      end)

      stub(Secret, :create, fn _kc,
                               "fluxvale-app-ns",
                               "access-domain-cert-" <> tail,
                               data,
                               labels ->
        send(parent, {:replica_name, tail, data, labels})
        {:ok, %{}}
      end)

      assert {:ok, local} = EdgeRoutes.ensure_access_cert_secret(%{}, domain, "fluxvale-app-ns")
      assert local =~ ~r/^access-domain-cert-[0-9a-f]{10}$/

      assert_received {:replica_name, replica_tail, data, labels}
      assert local == "access-domain-cert-#{replica_tail}"
      assert data == %{"tls.crt" => "CERT-PEM", "tls.key" => "KEY-PEM"}
      assert labels["fluxvale.io/access-domain"] == domain.id
    end

    test "ensure_access_cert_secret reports a malformed source" do
      stub_kubeconfig()
      owner = user()
      domain = custom_domain!(owner, verified?: true)

      stub(Secret, :get_data, fn _kc, _ns, _name -> {:ok, %{"tls.crt" => "CERT-PEM"}} end)

      assert {:error, :cert_secret_malformed} =
               EdgeRoutes.ensure_access_cert_secret(%{}, domain, "ns")
    end

    test "a :needs_attention custom domain WITH a cert ref keeps routing (the healing state)" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = custom_domain!(owner, verified?: true)

      domain
      |> Ash.Changeset.for_update(:mark_needs_attention, %{}, authorize?: false)
      |> Ash.update!()

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: domain.id, label: "wiki"},
        authorize?: false
      )

      stub_access_targets(ns)
      stub_cert_source()

      expect(Ingress, :create, 2, fn
        _kc, ^ns, "access-" <> _tail, %{host: "wiki." <> _tail} = spec ->
          # The cert is still valid while the reconcile limb heals — the
          # wake-flip must not take the hostnames dark mid-renewal-trouble.
          assert spec.tls_secret_name =~ ~r/^access-domain-cert-[0-9a-f]{10}$/
          {:ok, %{}}

        _kc, ^ns, _name, _spec ->
          # The default platform hostname — an ordinary mint.
          {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_access_wake(%{}, gateway_stub(), instance)
    end

    test "a :needs_attention custom domain with NO cert ref is skipped" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)

      domain = custom_domain!(owner)

      domain
      |> Ash.Changeset.for_update(:mark_needs_attention, %{}, authorize?: false)
      |> Ash.update!()

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: domain.id, label: "dark"},
        authorize?: false
      )

      stub_access_targets("fluxvale-app-#{instance.id}")

      stub(Ingress, :create, fn
        _kc, _ns, _name, %{host: "dark." <> _tail} ->
          flunk("a needs_attention domain with no ref must never route")

        _kc, _ns, _name, _spec ->
          {:ok, %{}}
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_access_wake(%{}, gateway_stub(), instance)
        end)

      assert log =~ "not servable"
    end

    test "a route apply failure propagates — never a half-minted posture" do
      stub_kubeconfig()
      instance = instance!(%{})
      stub_access_targets("fluxvale-app-#{instance.id}")

      stub(Ingress, :create, fn _kc, _ns, _name, _spec ->
        {:error, Error.connection_error("routes refused")}
      end)

      assert {:error, _error} = EdgeRoutes.apply_access_serving(%{}, gateway_stub(), instance)
    end

    test "idempotent — SSA re-apply converges on the same object set" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"

      expect(Service, :create, 2, fn _kc, ^ns, "wake", _spec -> {:ok, %{}} end)
      expect(Middleware, :create, 4, fn _kc, ^ns, _name, _spec -> {:ok, %{}} end)
      expect(Ingress, :create, 2, fn _kc, ^ns, "access-" <> _tail, _spec -> {:ok, %{}} end)

      assert :ok = EdgeRoutes.apply_access_serving(%{}, gateway_stub(), instance)
      assert :ok = EdgeRoutes.apply_access_serving(%{}, gateway_stub(), instance)
    end
  end

  describe "apply_access_wake/3 (ADR-0040 §7)" do
    test "the same hostnames target the platform through the wake Service, pair in the path" do
      stub_kubeconfig()
      gateway = gateway_stub()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"
      hostname = hostname_host!(instance.id)

      expect(Service, :create, fn _kc, ^ns, "wake", spec ->
        assert spec.external_name == "fluxvale-platform.fluxvale-dev.svc.cluster.local"
        assert spec.port == 4000
        {:ok, %{}}
      end)

      # The rewrite IS the authorization's carrier (#301's contract,
      # verbatim through the Traefik hop).
      expect(Middleware, :create, fn _kc, ^ns, "fluxvale-access-wake", spec ->
        assert spec.replace_path_regex == %{
                 regex: "^/(.*)",
                 replacement: "/internal/access/#{gateway.id}/#{instance.id}/$1"
               }

        {:ok, %{}}
      end)

      expect(Ingress, :create, fn _kc, ^ns, "access-" <> _tail, spec ->
        assert spec.host == "#{hostname.label}.#{hostname.access_domain.domain}"
        assert spec.entrypoint == "access"
        # The platform via the same ExternalName `wake` pattern...
        assert spec.service_name == "wake"
        assert spec.service_port == 4000
        # ...with the rewrite in front and NO beacon (mirror the public
        # wake arm — nothing is being forwarded).
        assert spec.middlewares == ["fluxvale-access-wake"]
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_access_wake(%{}, gateway, instance)
    end

    test "an unverified custom domain is skipped in wake mode too" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)
      ns = "fluxvale-app-#{instance.id}"

      custom_hostname!(owner, instance, "dark")

      stub(Service, :create, fn _kc, ^ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, ^ns, _n, _spec -> {:ok, %{}} end)

      stub(Ingress, :create, fn
        _kc, _ns, _name, %{host: "dark." <> _tail} ->
          flunk("an unverified custom domain must never route")

        _kc, _ns, _name, _spec ->
          # The default platform hostname — an ordinary mint.
          {:ok, %{}}
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_access_wake(%{}, gateway_stub(), instance)
        end)

      assert log =~ "not servable"
    end

    test "idempotent — the wake flip re-applies its full object set" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"

      expect(Service, :create, 2, fn _kc, ^ns, "wake", _spec -> {:ok, %{}} end)
      # Wake mode mints only the rewrite middleware — no beacon (mirror
      # the public wake arm).
      expect(Middleware, :create, 2, fn _kc, ^ns, _name, _spec -> {:ok, %{}} end)
      expect(Ingress, :create, 2, fn _kc, ^ns, "access-" <> _tail, _spec -> {:ok, %{}} end)

      assert :ok = EdgeRoutes.apply_access_wake(%{}, gateway_stub(), instance)
      assert :ok = EdgeRoutes.apply_access_wake(%{}, gateway_stub(), instance)
    end
  end

  describe "apply_access_none/2 (ADR-0040 §7)" do
    test "safe-deletes every hostname's access route plus the wake middleware" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)
      ns = "fluxvale-app-#{instance.id}"

      custom_hostname!(owner, instance, "wiki", verified?: true)

      # Two hostname rows (the default slug + the custom one), two
      # routes; plus the middleware.
      expect(Ingress, :delete, 2, fn _kc, ^ns, "access-" <> _tail -> :ok end)
      expect(Middleware, :delete, fn _kc, ^ns, "fluxvale-access-wake" -> :ok end)

      assert :ok = EdgeRoutes.apply_access_none(%{}, instance)
    end

    test "404s tolerated — the posture already holding, so the call is idempotent" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"

      stub(Ingress, :delete, fn _kc, ^ns, "access-" <> _tail ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub_middleware_delete(ns)

      assert :ok = EdgeRoutes.apply_access_none(%{}, instance)
      assert :ok = EdgeRoutes.apply_access_none(%{}, instance)
    end

    test "a delete failure propagates" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"

      stub(Ingress, :delete, fn _kc, ^ns, _name ->
        {:error, Error.connection_error("delete refused")}
      end)

      assert {:error, _error} = EdgeRoutes.apply_access_none(%{}, instance)
    end

    test "a middleware-delete failure propagates too — never a half-removed posture" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"

      stub(Ingress, :delete, fn _kc, ^ns, "access-" <> _tail -> :ok end)

      stub(Middleware, :delete, fn _kc, ^ns, "fluxvale-access-wake" ->
        {:error, Error.connection_error("middleware delete refused")}
      end)

      assert {:error, _error} = EdgeRoutes.apply_access_none(%{}, instance)
    end
  end

  describe "apply_access_none_for_domain/3 (the S6 ladder's honest-dark limb)" do
    test "removes ONLY that domain's routes — other hostnames and the middleware stand" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain_a = custom_domain!(owner, verified?: true)
      domain_b = custom_domain!(owner, verified?: true)

      row_a =
        InstanceHostname.mint!(
          %{instance_id: instance.id, access_domain_id: domain_a.id, label: "wiki"},
          authorize?: false
        )

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: domain_b.id, label: "other"},
        authorize?: false
      )

      # Exactly domain A's route goes — computed by the object_name
      # discipline (the random tail of the hostname row's id).
      tail =
        row_a.id
        |> to_string()
        |> String.replace("-", "")
        |> String.slice(-10, 10)

      expected = "access-" <> tail

      expect(Ingress, :delete, fn _kc, ^ns, ^expected -> :ok end)

      # Domain B's route and the wake middleware stay: honest dark is
      # domain-scoped, not instance-scoped.
      stub(Ingress, :delete, fn _kc, ^ns, "access-" <> _tail ->
        flunk("another domain's route must not be removed by a domain-scoped none")
      end)

      reject(Middleware, :delete, 3)

      assert :ok = EdgeRoutes.apply_access_none_for_domain(%{}, instance, domain_a)
    end

    test "404s tolerated — idempotent like the instance-scoped none" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)

      domain = custom_domain!(owner, verified?: true)

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: domain.id, label: "wiki"},
        authorize?: false
      )

      stub(Ingress, :delete, fn _kc, _ns, "access-" <> _tail ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert :ok = EdgeRoutes.apply_access_none_for_domain(%{}, instance, domain)
      assert :ok = EdgeRoutes.apply_access_none_for_domain(%{}, instance, domain)
    end

    test "a delete failure propagates" do
      stub_kubeconfig()
      owner = user()
      instance = instance!(%{}, %{}, owner)

      domain = custom_domain!(owner, verified?: true)

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: domain.id, label: "wiki"},
        authorize?: false
      )

      stub(Ingress, :delete, fn _kc, _ns, "access-" <> _tail ->
        {:error, Error.connection_error("delete refused")}
      end)

      assert {:error, _error} =
               EdgeRoutes.apply_access_none_for_domain(%{}, instance, domain)
    end
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

  describe "apply_private/2 (#265)" do
    test "deletes the app and dav routes, minting nothing" do
      stub_kubeconfig()
      instance = instance!(%{file_access: true})
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, 2, fn
        _kc, ^ns, "app-ingress" -> :ok
        _kc, ^ns, "app-dav" -> :ok
      end)

      # The posture owns routes only: no middleware, no service, and
      # no route may be minted — reaching for create fails the test.
      reject(Ingress, :create, 4)
      reject(Middleware, :create, 4)
      reject(Service, :create, 4)

      assert :ok = EdgeRoutes.apply_private(%{}, instance)
    end

    test "a missing route is the posture already holding (404 tolerated)" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert :ok = EdgeRoutes.apply_private(%{}, instance)
    end

    test "a volume-less file-access instance hunts no dav route" do
      stub_kubeconfig()
      instance = instance!(%{file_access: true}, storage_gb: 0)
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" -> :ok end)

      stub(Ingress, :delete, fn
        _kc, _ns, "app-dav" -> flunk("no dav route ever existed to delete")
        _kc, _ns, "app-ingress" -> :ok
      end)

      assert :ok = EdgeRoutes.apply_private(%{}, instance)
    end

    test "a delete failure propagates — never a half-private posture" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" ->
        {:error, Error.connection_error("delete refused")}
      end)

      assert {:error, _error} = EdgeRoutes.apply_private(%{}, instance)
    end

    test "apply_serving and apply_wake converge on it for private instances" do
      stub_kubeconfig()
      instance = instance!(%{})
      ns = "fluxvale-app-#{instance.id}"

      private = InstanceFixtures.pin!(instance, exposure: :private)

      expect(Ingress, :delete, 2, fn _kc, ^ns, _name -> :ok end)
      reject(Ingress, :create, 4)

      assert :ok = EdgeRoutes.apply_serving(%{}, private)
      assert :ok = EdgeRoutes.apply_wake(%{}, private)
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

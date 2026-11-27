defmodule FluxVale.Infrastructure.Operations.EdgeRoutesPublicHostnameTest do
  @moduledoc false

  # The public custom family (the public-custom-address lane, P1): one
  # websecure route per CUSTOM hostname row on a PUBLIC instance, torn
  # down from the private posture. Same stance as edge_routes_test —
  # the k8s applies are stubbed; the manifest maps are the assertion
  # surface.

  use FluxVale.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  setup do
    AccessFixtures.stub_gateway_pod()
    InstanceFixtures.local_cluster!()

    {org, owner} = BillingFixtures.grant_free_org!()

    # Instance creates carry #124's funded gate.
    {:ok, _wallet} = Billing.ensure_wallet(org)
    {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

    # The domain fixtures' wildcard-Certificate mint (panel parity)
    # rides these cluster stubs — both kubeconfig arities (the fixture
    # registers through the action; the applies here pass kubeconfigs
    # directly).
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)

    %{org: org, owner: owner}
  end

  # The object_name short_id discipline under test: the row id's last
  # 10 hex chars (the RANDOM TAIL — never the uuid head).
  defp tail(id) do
    id
    |> to_string()
    |> String.replace("-", "")
    |> String.slice(-10, 10)
  end

  defp default_row!(instance_id) do
    row =
      InstanceHostname
      |> Ash.Query.filter(instance_id == ^instance_id)
      |> Ash.read_one!(authorize?: false)

    Ash.load!(row, :access_domain, authorize?: false)
  end

  # file_access is catalog-declared on the app VERSION and derived at
  # create — never a direct create input (the dav-prefix-guard test's
  # note). The org pins the same way AccessFixtures does.
  defp file_access_instance!(org, owner) do
    version = InstanceFixtures.app_version!(%{file_access: true})

    instance =
      Instance.create!(
        %{
          name: "App #{System.unique_integer()}",
          app_version_id: version.id,
          env_vars: %{},
          storage_gb: 10
        },
        actor: owner
      )

    pinned =
      InstanceFixtures.pin!(instance,
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now()
      )

    pinned
    |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:organization_id, org.id)
    |> Ash.update!()
    |> InstanceFixtures.walk_to!(:running)
  end

  # A public row pinned at a funnel-legal status (the set_exposure
  # test's deployed_instance! shape) — the dispatch test's subjects.
  defp public_instance_at!(org, owner, status) do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    pinned =
      InstanceFixtures.pin!(instance,
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now()
      )

    pinned
    |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:organization_id, org.id)
    |> Ash.update!()
    |> InstanceFixtures.walk_to!(status)
  end

  defp stub_public_targets(ns) do
    stub(Service, :create, fn _kc, ^ns, "wake", _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, ^ns, _name, _spec -> {:ok, %{}} end)
  end

  # The cert replica's source (the access namespace Secret the fleet's
  # cert-manager writes) and its per-namespace replica — the same
  # replication the access arm uses, reused unchanged.
  defp stub_cert_source do
    stub(Secret, :get_data, fn _kc, "fluxvale-access", "cert-secret-" <> _rest ->
      {:ok, %{"tls.crt" => "CERT-PEM", "tls.key" => "KEY-PEM"}}
    end)

    stub(Secret, :create, fn _kc, _ns, "access-domain-cert-" <> _tail, _data, _labels ->
      {:ok, %{}}
    end)
  end

  defp not_found do
    {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
  end

  defp drain_created(acc \\ []) do
    receive do
      {:created, name} -> drain_created([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_created_specs(acc \\ []) do
    receive do
      {:created, name, spec} -> drain_created_specs([{name, spec} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # One ordered drain of every edge call the test's stubs recorded —
  # the mailbox order IS the call order, so this can pin sequence where
  # assert_received cannot (it matches any mailbox position).
  defp drain_events(acc \\ []) do
    receive do
      {:wake_targets} -> drain_events([{:wake_targets} | acc])
      {:created, name, spec} -> drain_events([{:created, name, spec} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_deleted(acc \\ []) do
    receive do
      {:deleted, name} -> drain_deleted([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the public custom mint (serving)" do
    test "mints a websecure route per custom hostname row on a public instance", %{
      org: org,
      owner: owner
    } do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row_a = AccessFixtures.mint_hostname!(instance, domain, "git")
      row_b = AccessFixtures.mint_hostname!(instance, domain, "wiki")

      stub_public_targets(ns)
      stub_cert_source()

      parent = self()

      stub(Ingress, :create, fn _kc, ^ns, name, spec ->
        send(parent, {:created, name, spec})
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_serving(%{}, instance)

      # The default hostname's flow is untouched, and each custom row
      # gains its own route keyed on the row id's random tail.
      assert_received {:created, "app-ingress", _default_spec}

      assert_received {:created, "custom-" <> tail_a = name_a, spec_a}
      assert name_a == "custom-" <> tail(row_a.id)
      assert tail_a == tail(row_a.id)
      assert spec_a.host == "git.#{domain.domain}"

      assert_received {:created, "custom-" <> tail_b, spec_b}
      assert tail_b == tail(row_b.id)
      assert spec_b.host == "wiki.#{domain.domain}"

      # The websecure shape: NO :entrypoint — `tls: true` alone picks
      # websecure in the builder, exactly like app-ingress.
      refute Map.has_key?(spec_a, :entrypoint)
      assert spec_a.tls
      assert spec_a.service_name == "app"
      assert spec_a.service_port == 80
      assert spec_a.middlewares == ["fluxvale-activity"]
      assert spec_a.labels["fluxvale.io/access-domain"] == domain.id

      # TLS rides the LOCAL cert replica the existing clause replicates
      # — never the cross-namespace source (Traefik reads the route's
      # own namespace), and no source-ip clause (that is the access
      # edge's private-plane gate, never the public family's).
      assert spec_a.tls_secret_name == "access-domain-cert-" <> tail(domain.id)
      refute Map.has_key?(spec_a, :source_ip)
    end

    test "the platform-domain default row gets no route in the new family", %{
      org: org,
      owner: owner
    } do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      # THE TRAP's fixture: every instance holds the platform row.
      row = default_row!(instance.id)
      assert row.access_domain.kind == :platform

      stub_public_targets(ns)

      parent = self()

      stub(Ingress, :create, fn _kc, ^ns, name, _spec ->
        send(parent, {:created, name})
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_serving(%{}, instance)

      names = drain_created()
      assert "app-ingress" in names
      # A second router on Host(<slug>.fluxvale.app) would be a
      # same-host collision with app-ingress — none is minted.
      refute Enum.any?(names, &String.starts_with?(&1, "custom-"))
    end

    test "an unverified domain mints nothing public", %{org: org, owner: owner} do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.custom_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "dark")

      stub_public_targets(ns)

      parent = self()

      stub(Ingress, :create, fn
        _kc, ^ns, "custom-" <> _tail, _spec ->
          flunk("a pending custom domain must never route publicly")

        _kc, ^ns, _name, _spec ->
          # The default platform hostname — an ordinary mint.
          {:ok, %{}}
      end)

      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_serving(%{}, instance)
        end)

      # Dark is the posture: nothing minted, and any standing route for
      # the row came down.
      assert log =~ "not servable"
      assert_received {:deleted, "custom-" <> deleted_tail}
      assert deleted_tail == tail(row.id)
      refute_received {:deleted, "custom-" <> _dav}
    end

    test "a file-access instance's dark domain loses the dav sibling too", %{
      org: org,
      owner: owner
    } do
      instance = file_access_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.custom_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "dark")

      stub_public_targets(ns)

      stub(Ingress, :create, fn
        _kc, ^ns, "custom-" <> _tail, _spec ->
          flunk("a pending custom domain must never route")

        _kc, ^ns, _name, _spec ->
          {:ok, %{}}
      end)

      parent = self()

      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_serving(%{}, instance)
        end)

      assert log =~ "not servable"

      # Dark takes the row's whole pair down — the dav sibling with it.
      assert_received {:deleted, "custom-" <> app_tail}
      assert app_tail == tail(row.id)

      assert_received {:deleted, "custom-" <> dav_tail}
      assert dav_tail == tail(row.id) <> "-dav"
    end

    test "a foreign-org row never routes publicly", %{org: org, owner: owner} do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      # A row under ANOTHER org's verified domain — out-of-band today;
      # the belt must refuse it (fail closed), like the access arm's.
      {foreign_org, _foreign_owner} = BillingFixtures.grant_free_org!()
      foreign_domain = AccessFixtures.verified_domain!(foreign_org)

      row = AccessFixtures.mint_hostname!(instance, foreign_domain, "foreign")

      stub_public_targets(ns)

      parent = self()

      stub(Ingress, :create, fn
        _kc, ^ns, "custom-" <> _tail, _spec ->
          flunk("a foreign-org row must never route publicly")

        _kc, ^ns, _name, _spec ->
          {:ok, %{}}
      end)

      # The belt is not mint-only: a route minted while the row WAS
      # legitimately owned comes down too.
      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_serving(%{}, instance)
        end)

      assert log =~ "another organization"
      assert_received {:deleted, "custom-" <> deleted_tail}
      assert deleted_tail == tail(row.id)
      refute_received {:deleted, _}
    end

    test "a file-access instance's custom row gains a dav sibling under the path prefix", %{
      org: org,
      owner: owner
    } do
      instance = file_access_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")

      stub_public_targets(ns)
      stub_cert_source()

      parent = self()

      stub(Ingress, :create, fn _kc, ^ns, name, spec ->
        send(parent, {:created, name, spec})
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_serving(%{}, instance)

      assert_received {:created, "custom-" <> app_tail, app_spec}
      assert app_tail == tail(row.id)
      assert app_spec.service_name == "app"

      # The sibling rides the row's name, narrows to the path prefix,
      # dials the dav Service, and shares the app route's TLS posture.
      assert_received {:created, "custom-" <> dav_tail, dav_spec}
      assert dav_tail == tail(row.id) <> "-dav"
      assert dav_spec.host == "git.#{domain.domain}"
      assert dav_spec.service_name == "dav"
      assert dav_spec.service_port == 80
      assert dav_spec.path_prefix == "/dav"
      assert dav_spec.middlewares == ["fluxvale-activity"]
      assert dav_spec.tls
      assert dav_spec.tls_secret_name == app_spec.tls_secret_name
    end

    test "a serving dav failure stops before the custom routes", %{org: org, owner: owner} do
      instance = file_access_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.mint_hostname!(instance, domain, "git")

      stub_public_targets(ns)
      stub_cert_source()

      stub(Ingress, :create, fn
        _kc, ^ns, "app-dav", _spec ->
          {:error, Error.connection_error("dav refused")}

        _kc, ^ns, "custom-" <> _tail, _spec ->
          flunk("a failed dav mint must stop the walk before the custom routes")

        _kc, ^ns, _name, _spec ->
          {:ok, %{}}
      end)

      assert {:error, _error} = EdgeRoutes.apply_serving(%{}, instance)
    end

    test "a blank file_access path_prefix config skips the public custom dav route too", %{
      org: org,
      owner: owner
    } do
      instance = file_access_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")

      stub_public_targets(ns)
      stub_cert_source()

      file_access_config = Application.fetch_env!(:flux_vale, :file_access)

      Application.put_env(
        :flux_vale,
        :file_access,
        Keyword.put(file_access_config, :path_prefix, nil)
      )

      on_exit(fn -> Application.put_env(:flux_vale, :file_access, file_access_config) end)

      stub(Ingress, :create, fn
        _kc, ^ns, "custom-" <> _tail, %{path_prefix: _prefix} ->
          flunk("a nil prefix must skip the dav mint, not carry it through")

        _kc, ^ns, _name, _spec ->
          {:ok, %{}}
      end)

      parent = self()

      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_serving(%{}, instance)
        end)

      assert log =~ "Public edge: skipping the /dav route"
      assert log =~ "bare-Host router"

      # The guard is not mint-only: a sibling minted under an earlier
      # valid prefix comes down with the skip.
      assert_received {:deleted, "custom-" <> dav_tail}
      assert dav_tail == tail(row.id) <> "-dav"
      refute_received {:deleted, _}
    end

    test "a custom route apply failure propagates — never a half-minted posture", %{
      org: org,
      owner: owner
    } do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.mint_hostname!(instance, domain, "git")

      stub_public_targets(ns)
      stub_cert_source()

      stub(Ingress, :create, fn
        _kc, ^ns, "custom-" <> _tail, _spec ->
          {:error, Error.connection_error("custom route refused")}

        _kc, ^ns, _name, _spec ->
          {:ok, %{}}
      end)

      assert {:error, _error} = EdgeRoutes.apply_serving(%{}, instance)
    end

    test "a custom dav create failure propagates — never a half-minted row", %{
      org: org,
      owner: owner
    } do
      instance = file_access_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")

      stub_public_targets(ns)
      stub_cert_source()

      dav_name = "custom-" <> tail(row.id) <> "-dav"

      stub(Ingress, :create, fn
        # ONLY the dav sibling is refused — the app route lands first,
        # so this is the maybe_mint_custom_dav error arm under test.
        _kc, ^ns, ^dav_name, _spec ->
          {:error, Error.connection_error("custom dav refused")}

        _kc, ^ns, _name, _spec ->
          {:ok, %{}}
      end)

      assert {:error, _error} = EdgeRoutes.apply_serving(%{}, instance)
    end
  end

  describe "the public custom wake flip" do
    test "a sleeping public instance's custom route targets the wake service", %{
      org: org,
      owner: owner
    } do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")
      sleeping = AccessFixtures.sleep!(instance)

      stub_cert_source()

      parent = self()

      stub(Service, :create, fn _kc, ^ns, "wake", _spec ->
        send(parent, {:wake_targets})
        {:ok, %{}}
      end)

      stub(Middleware, :create, fn _kc, ^ns, _name, _spec -> {:ok, %{}} end)

      stub(Ingress, :create, fn _kc, ^ns, name, spec ->
        send(parent, {:created, name, spec})
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_wake(%{}, sleeping)

      # The wake targets landed FIRST (#203): a rewritten route must
      # only reference objects Traefik already watches. One ordered
      # drain is the proof — assert_received would match any mailbox
      # position, so the reversed order would still pass it.
      events = drain_events()

      wake_index =
        Enum.find_index(events, fn
          {:wake_targets} -> true
          _other -> false
        end)

      custom_index =
        Enum.find_index(events, fn
          {:created, name, _spec} -> name == "custom-" <> tail(row.id)
          _other -> false
        end)

      assert wake_index != nil and custom_index != nil
      assert wake_index < custom_index

      assert {:created, custom_name, spec} =
               Enum.find(events, fn
                 {:created, name, _spec} -> name == "custom-" <> tail(row.id)
                 _other -> false
               end)

      assert custom_name == "custom-" <> tail(row.id)
      assert spec.service_name == "wake"
      assert spec.service_port == 4000
      assert spec.middlewares == ["fluxvale-wake"]
      assert spec.tls
      assert spec.tls_secret_name == "access-domain-cert-" <> tail(domain.id)
    end

    test "an unverified domain is torn dark on the sleep flip too", %{org: org, owner: owner} do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.custom_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "dark")
      sleeping = AccessFixtures.sleep!(instance)

      stub_public_targets(ns)

      stub(Ingress, :create, fn
        _kc, ^ns, "custom-" <> _tail, _spec ->
          flunk("a pending custom domain must never route, even in wake mode")

        _kc, ^ns, _name, _spec ->
          {:ok, %{}}
      end)

      parent = self()

      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      log =
        capture_log(fn ->
          assert :ok = EdgeRoutes.apply_wake(%{}, sleeping)
        end)

      assert log =~ "not servable"
      assert_received {:deleted, "custom-" <> deleted_tail}
      assert deleted_tail == tail(row.id)
    end

    test "the custom dav sibling flips to wake mode with the prefix kept", %{
      org: org,
      owner: owner
    } do
      instance = file_access_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")
      sleeping = AccessFixtures.sleep!(instance)

      stub_public_targets(ns)
      stub_cert_source()

      parent = self()

      stub(Ingress, :create, fn _kc, ^ns, name, spec ->
        send(parent, {:created, name, spec})
        {:ok, %{}}
      end)

      assert :ok = EdgeRoutes.apply_wake(%{}, sleeping)

      created = drain_created_specs()
      app_row_tail = tail(row.id)

      app =
        Enum.find(created, fn {name, _spec} -> name == "custom-" <> app_row_tail end)

      dav =
        Enum.find(created, fn {name, _spec} ->
          name == "custom-" <> app_row_tail <> "-dav"
        end)

      assert app != nil and dav != nil
      assert elem(app, 1).service_name == "wake"
      assert elem(app, 1).middlewares == ["fluxvale-wake"]

      # Wake keeps the wake target and the PUBLIC marker middleware —
      # never the access rewrite — and narrows to the path prefix.
      assert elem(dav, 1).service_name == "wake"
      assert elem(dav, 1).middlewares == ["fluxvale-wake"]
      assert elem(dav, 1).path_prefix == "/dav"
    end

    test "apply_public_for_status dispatches sleeping to wake and the rest to serving", %{
      org: org,
      owner: owner
    } do
      domain = AccessFixtures.verified_domain!(org)
      stub_cert_source()

      parent = self()

      stub(Ingress, :create, fn _kc, _ns, name, spec ->
        send(parent, {:created, name, spec})
        {:ok, %{}}
      end)

      # SetExposure's rule IS the public plane's convention: only
      # :sleeping flips to wake (the waking page) — a :starting row
      # mid-deploy and a :stopped one still serve.
      for status <- [:running, :starting, :stopped] do
        instance = public_instance_at!(org, owner, status)
        stub_public_targets("fluxvale-app-#{instance.id}")
        row = AccessFixtures.mint_hostname!(instance, domain, "row-#{status}")

        assert :ok = EdgeRoutes.apply_public_for_status(%{}, instance)

        assert_received {:created, "custom-" <> serving_tail, serving_spec}
        assert serving_tail == tail(row.id)
        assert serving_spec.service_name == "app"
        assert serving_spec.middlewares == ["fluxvale-activity"]
      end

      sleeper = public_instance_at!(org, owner, :sleeping)
      stub_public_targets("fluxvale-app-#{sleeper.id}")
      row = AccessFixtures.mint_hostname!(sleeper, domain, "row-sleeping")

      assert :ok = EdgeRoutes.apply_public_for_status(%{}, sleeper)

      assert_received {:created, "custom-" <> wake_tail, wake_spec}
      assert wake_tail == tail(row.id)
      assert wake_spec.service_name == "wake"
      assert wake_spec.middlewares == ["fluxvale-wake"]
    end

    # The one-owner undeployed gate: a never-deployed instance has no
    # namespace to route into, so nothing applies and :ok is the
    # posture already holding — the mint, the janitor, and the coming
    # drift limb converge here instead of forking a nil-namespace
    # guard of their own.
    test "apply_public_for_status answers ok for an undeployed instance", %{owner: owner} do
      version = InstanceFixtures.app_version!()

      instance =
        Instance.create!(
          %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      assert is_nil(instance.namespace)
      assert instance.exposure == :public

      # Nothing to apply: zero cluster calls — the gate answers before
      # the arms.
      reject(Ingress, :create, 4)
      reject(Middleware, :create, 4)
      reject(Service, :create, 4)

      assert :ok = EdgeRoutes.apply_public_for_status(%{}, instance)
    end
  end

  describe "the public custom teardown" do
    test "apply_private deletes the custom routes", %{org: org, owner: owner} do
      instance = file_access_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")

      parent = self()

      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      # The posture owns routes only: nothing may be minted.
      reject(Ingress, :create, 4)
      reject(Middleware, :create, 4)
      reject(Service, :create, 4)

      assert :ok = EdgeRoutes.apply_private(%{}, instance)

      names = drain_deleted()
      # The default flow's deletes stay, and every custom route —
      # app and dav sibling — comes down with them.
      assert "app-ingress" in names
      assert "app-dav" in names
      assert ("custom-" <> tail(row.id)) in names
      assert ("custom-" <> tail(row.id) <> "-dav") in names
    end

    test "a private instance mints no websecure route for its custom hostname", %{
      org: org,
      owner: owner
    } do
      instance = AccessFixtures.private_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")

      stub_cert_source()

      stub(Ingress, :create, fn
        _kc, ^ns, "custom-" <> _tail, _spec ->
          flunk("a private instance must never mint a public custom route")

        _kc, ^ns, _name, _spec ->
          {:ok, %{}}
      end)

      parent = self()

      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      # apply_serving converges on the private posture: nothing minted,
      # and the custom route comes down with the default's.
      assert :ok = EdgeRoutes.apply_serving(%{}, instance)

      names = drain_deleted()
      assert "app-ingress" in names
      assert ("custom-" <> tail(row.id)) in names
    end

    test "apply_public_none_for_hostname removes one row's public routes — dav included, nothing else",
         %{
           org: org,
           owner: owner
         } do
      instance = file_access_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")

      parent = self()

      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      assert :ok = EdgeRoutes.apply_public_none_for_hostname(%{}, instance, row)

      # Exactly the row's pair — the default hostname's routes are not
      # this limb's business.
      assert_received {:deleted, "custom-" <> app_tail}
      assert app_tail == tail(row.id)

      assert_received {:deleted, "custom-" <> dav_tail}
      assert dav_tail == tail(row.id) <> "-dav"
      refute_received {:deleted, _}
    end

    test "apply_public_none_for_domain removes only its own domain's routes", %{
      org: org,
      owner: owner
    } do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain_a = AccessFixtures.verified_domain!(org)
      domain_b = AccessFixtures.verified_domain!(org)

      row_a = AccessFixtures.mint_hostname!(instance, domain_a, "wiki")
      _row_b = AccessFixtures.mint_hostname!(instance, domain_b, "other")

      parent = self()

      stub(Ingress, :delete, fn _kc, ^ns, name ->
        send(parent, {:deleted, name})
        :ok
      end)

      assert :ok = EdgeRoutes.apply_public_none_for_domain(%{}, instance, domain_a)

      # Exactly domain A's route goes — domain B's is never touched.
      assert_received {:deleted, "custom-" <> deleted_tail}
      assert deleted_tail == tail(row_a.id)
      refute_received {:deleted, _}
    end

    test "the public none limbs and the private posture tolerate 404s — idempotent", %{
      org: org,
      owner: owner
    } do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")

      stub(Ingress, :delete, fn
        _kc, ^ns, "app-ingress" -> not_found()
        _kc, ^ns, "custom-" <> _tail -> not_found()
      end)

      assert :ok = EdgeRoutes.apply_public_none_for_hostname(%{}, instance, row)
      assert :ok = EdgeRoutes.apply_public_none_for_domain(%{}, instance, domain)
      assert :ok = EdgeRoutes.apply_private(%{}, instance)
    end

    test "a custom-route delete failure propagates from every tearing limb", %{
      org: org,
      owner: owner
    } do
      instance = AccessFixtures.public_instance!(org, owner)
      ns = "fluxvale-app-#{instance.id}"

      domain = AccessFixtures.verified_domain!(org)
      row = AccessFixtures.mint_hostname!(instance, domain, "git")

      refused = Error.connection_error("delete refused")

      stub(Ingress, :delete, fn
        _kc, ^ns, "app-ingress" -> :ok
        _kc, ^ns, "custom-" <> _tail -> {:error, refused}
      end)

      assert {:error, ^refused} = EdgeRoutes.apply_private(%{}, instance)
      assert {:error, ^refused} = EdgeRoutes.apply_public_none_for_hostname(%{}, instance, row)

      assert {:error, ^refused} =
               EdgeRoutes.apply_public_none_for_domain(%{}, instance, domain)
    end
  end
end

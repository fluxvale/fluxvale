defmodule FluxVale.Clients.K8s.Resources.IngressTest do
  use ExUnit.Case, async: true
  use Mimic

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress

  defp route_match(manifest), do: get_in(manifest, ["spec", "routes", Access.at(0), "match"])

  defp base_spec do
    %{subdomain: "my-app", service_name: "my-app", service_port: 80}
  end

  describe "create/4 — DNS-name gate" do
    test "rejects a hostile host before any cluster call (no crash on nil kubeconfig)" do
      spec = Map.put(base_spec(), :host, "a`) || PathPrefix(`/")

      assert {:error, %Error{reason: :invalid_spec, message: msg}} =
               Ingress.create(nil, "ns", "evil", spec)

      assert msg =~ "a`) || PathPrefix"
    end

    test "rejects backslash/backtick subdomains" do
      spec = Map.put(base_spec(), :subdomain, "x\\`, Other(`y")

      assert {:error, %Error{reason: :invalid_spec}} = Ingress.create(nil, "ns", "evil", spec)
    end

    test "rejects a trailing newline ($ would match before it — \\z does not)" do
      spec = Map.put(base_spec(), :host, "evil.com\n")

      assert {:error, %Error{reason: :invalid_spec}} = Ingress.create(nil, "ns", "evil", spec)
    end
  end

  describe "build_manifest/3 — subdomain routing" do
    test "composes Host(`<subdomain>.<domain>`) with the service backend" do
      manifest = Ingress.build_manifest("fluxvale-app-1", "my-app", base_spec())

      assert manifest["apiVersion"] == "traefik.io/v1alpha1"
      assert manifest["kind"] == "IngressRoute"
      assert manifest["metadata"]["namespace"] == "fluxvale-app-1"
      assert manifest["metadata"]["labels"]["app.kubernetes.io/managed-by"] == "fluxvale"
      assert route_match(manifest) == "Host(`my-app.localhost`)"

      assert get_in(manifest, ["spec", "routes", Access.at(0), "services"]) == [
               %{"name" => "my-app", "port" => 80}
             ]
    end

    test "honors an explicit :domain" do
      manifest =
        Ingress.build_manifest("ns", "my-app", Map.put(base_spec(), :domain, "fluxvale.com"))

      assert route_match(manifest) == "Host(`my-app.fluxvale.com`)"
    end

    test "defaults to the web entryPoint without TLS" do
      manifest = Ingress.build_manifest("ns", "my-app", base_spec())

      assert get_in(manifest, ["spec", "entryPoints"]) == ["web"]
      refute Map.has_key?(manifest["spec"], "tls")
    end

    test "tls: true switches to websecure and prefers an existing secret over a resolver" do
      spec =
        base_spec()
        |> Map.put(:tls, true)
        |> Map.put(:tls_secret_name, "wildcard-tls")

      manifest = Ingress.build_manifest("ns", "my-app", spec)

      assert get_in(manifest, ["spec", "entryPoints"]) == ["websecure"]
      assert manifest["spec"]["tls"] == %{"secretName" => "wildcard-tls"}
    end

    test "tls: true without a secret requests one via the cert resolver" do
      manifest = Ingress.build_manifest("ns", "my-app", Map.put(base_spec(), :tls, true))

      assert manifest["spec"]["tls"] == %{"certResolver" => "letsencrypt"}
    end

    test "custom cert_resolver is honored" do
      spec =
        base_spec()
        |> Map.put(:tls, true)
        |> Map.put(:cert_resolver, "le-staging")

      manifest = Ingress.build_manifest("ns", "my-app", spec)

      assert manifest["spec"]["tls"] == %{"certResolver" => "le-staging"}
    end
  end

  describe "build_manifest/3 — custom-host routing (post-beta surface)" do
    test "matches the full host directly, ignoring subdomain/domain" do
      spec =
        base_spec()
        |> Map.put(:host, "myapp.example.com")
        |> Map.put(:domain, "ignored.example")

      manifest = Ingress.build_manifest("ns", "my-app", spec)

      assert route_match(manifest) == "Host(`myapp.example.com`)"
    end
  end

  describe "rule escaping — Traefik rule injection" do
    test "escapes backticks in subdomain" do
      manifest =
        Ingress.build_manifest(
          "ns",
          "evil",
          Map.put(base_spec(), :subdomain, "x`, PathPrefix(`/admin")
        )

      assert route_match(manifest) == "Host(`x\\`, PathPrefix(\\`/admin.localhost`)"
    end

    test "escapes backslashes before backticks" do
      manifest =
        Ingress.build_manifest("ns", "evil", Map.put(base_spec(), :subdomain, "x\\`, Other(`y"))

      assert route_match(manifest) == "Host(`x\\\\\\`, Other(\\`y.localhost`)"
    end

    test "escapes a hostile custom host too" do
      manifest =
        Ingress.build_manifest("ns", "evil", Map.put(base_spec(), :host, "a`) || PathPrefix(`/"))

      assert route_match(manifest) == "Host(`a\\`) || PathPrefix(\\`/`)"
    end
  end

  describe "create/4" do
    test "applies the IngressRoute for a valid subdomain" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert manifest["kind"] == "IngressRoute"
        assert manifest["metadata"]["namespace"] == "ns"
        assert field_manager == "fluxvale"
        {:ok, %{status: 201, body: manifest}}
      end)

      spec = %{subdomain: "my-app", service_name: "my-app", service_port: 80}
      assert {:ok, %{"kind" => "IngressRoute"}} = Ingress.create(%{}, "ns", "my-app", spec)
    end

    test "an invalid host is rejected before any API call" do
      spec = %{host: Enum.at(["bad`host"], 0), service_name: "app", service_port: 80}

      assert {:error, %Error{reason: :invalid_spec, message: msg}} =
               Ingress.create(%{}, "ns", "x", spec)

      assert msg =~ "Not a valid DNS name"
    end

    test "transport failure maps to a connection error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:error, :transport_oops} end)

      spec = %{subdomain: "my-app", service_name: "my-app", service_port: 80}
      assert {:error, %Error{reason: :connection_error}} = Ingress.create(%{}, "ns", "x", spec)
    end
  end

  describe "get/3" do
    test "returns the body on 200 (the happy read path)" do
      expect(Kubereq, :get, fn _req, namespace, name ->
        assert namespace == "ns"
        assert name == "my-app"
        {:ok, %{status: 200, body: %{"kind" => "IngressRoute"}}}
      end)

      assert {:ok, %{"kind" => "IngressRoute"}} = Ingress.get(%{}, "ns", "my-app")
    end

    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Ingress.get(%{}, "ns", "missing")
    end
  end

  describe "delete/3" do
    test "404 is :not_found" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Ingress.delete(%{}, "ns", "missing")
    end

    test "202 accepts asynchronous deletion" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 202}} end)

      assert :ok = Ingress.delete(%{}, "ns", "my-app")
    end
  end

  describe "upsert/4" do
    test "delegates to create (SSA idempotence)" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 201, body: :created}} end)

      assert {:ok, :created} =
               Ingress.upsert(%{}, "ns", "app", %{
                 subdomain: "my-app",
                 service_name: "my-app",
                 service_port: 80
               })
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "traefik.io/v1alpha1"
      assert opts[:kind] == "IngressRoute"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)
    Ingress.get(%{}, "ns", "x")
  end
end

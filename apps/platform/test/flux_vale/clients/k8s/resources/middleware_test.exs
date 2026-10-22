defmodule FluxVale.Clients.K8s.Resources.MiddlewareTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Middleware

  describe "build_manifest/3" do
    test "forward_auth carries the address and the UA request-header pass-through" do
      spec = %{
        forward_auth: %{
          address:
            "http://platform.fluxvale-dev.svc.cluster.local:4000/internal/edge/touch?instance=id",
          auth_request_headers: ["User-Agent"]
        }
      }

      manifest = Middleware.build_manifest("ns", "fluxvale-activity", spec)

      assert manifest["kind"] == "Middleware"
      assert manifest["apiVersion"] == "traefik.io/v1alpha1"

      assert manifest["spec"] == %{
               "forwardAuth" => %{
                 "address" => spec.forward_auth.address,
                 "authRequestHeaders" => ["User-Agent"]
               }
             }
    end

    test "request_headers lands as customRequestHeaders" do
      spec = %{request_headers: %{"X-FluxVale-Instance" => "an-id"}}

      manifest = Middleware.build_manifest("ns", "fluxvale-wake", spec)

      assert manifest["spec"] == %{
               "headers" => %{"customRequestHeaders" => %{"X-FluxVale-Instance" => "an-id"}}
             }
    end
  end

  describe "build_manifest/3 — the empty spec" do
    test "a spec with neither strategy builds an empty body (create rejects it)" do
      manifest = Middleware.build_manifest("ns", "m", %{})

      assert manifest["spec"] == %{}
    end
  end

  describe "create/4 — fail-loudly validation" do
    test "a non-http address is rejected before any cluster call" do
      spec = %{forward_auth: %{address: "gopher://nope"}}

      assert {:error, %Error{reason: :invalid_spec, message: msg}} =
               Middleware.create(nil, "ns", "bad", spec)

      assert msg =~ "http(s) URL"
    end

    test "an address carrying a newline is rejected (injection posture)" do
      spec = %{forward_auth: %{address: "http://ok.example/\nHost: evil"}}

      assert {:error, %Error{reason: :invalid_spec}} = Middleware.create(nil, "ns", "bad", spec)
    end

    test "a malformed authRequestHeader name is rejected" do
      spec = %{
        forward_auth: %{address: "http://ok.example/touch", auth_request_headers: ["Bad Header"]}
      }

      assert {:error, %Error{reason: :invalid_spec, message: msg}} =
               Middleware.create(nil, "ns", "bad", spec)

      assert msg =~ "header names"
    end

    test "a request-header NAME with a space is rejected (RFC 7230 token)" do
      spec = %{request_headers: %{"X FluxVale" => "id"}}

      assert {:error, %Error{reason: :invalid_spec, message: msg}} =
               Middleware.create(nil, "ns", "bad", spec)

      assert msg =~ "header names"
    end

    test "a header value with a newline is rejected" do
      spec = %{request_headers: %{"X-FluxVale-Instance" => "id\r\nX-Other: 1"}}

      assert {:error, %Error{reason: :invalid_spec, message: msg}} =
               Middleware.create(nil, "ns", "bad", spec)

      assert msg =~ "single-line"
    end

    test "an empty spec is rejected — a Middleware must do something" do
      assert {:error, %Error{reason: :invalid_spec, message: msg}} =
               Middleware.create(nil, "ns", "empty", %{})

      assert msg =~ "forward_auth or request_headers"
    end

    test "a valid beacon spec applies" do
      spec = %{
        forward_auth: %{address: "http://platform.svc:4000/internal/edge/touch?instance=x"}
      }

      stub(Kubereq, :apply, fn _req, _manifest, _manager -> {:ok, %{status: 201, body: %{}}} end)

      assert {:ok, _body} = Middleware.create(%{}, "ns", "fluxvale-activity", spec)
    end

    test "a valid marker spec applies" do
      spec = %{request_headers: %{"X-FluxVale-Instance" => "an-id"}}

      stub(Kubereq, :apply, fn _req, _manifest, _manager -> {:ok, %{status: 201, body: %{}}} end)

      assert {:ok, _body} = Middleware.create(%{}, "ns", "fluxvale-wake", spec)
    end
  end
end

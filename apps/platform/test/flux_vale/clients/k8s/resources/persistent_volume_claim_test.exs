defmodule FluxVale.Clients.K8s.Resources.PersistentVolumeClaimTest do
  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "build_manifest/3" do
    test "requests the size with ReadWriteOnce by default" do
      manifest = PersistentVolumeClaim.build_manifest("ns", "data", %{size: "1Gi"})

      assert manifest["kind"] == "PersistentVolumeClaim"
      assert manifest["spec"]["accessModes"] == ["ReadWriteOnce"]
      assert manifest["spec"]["resources"]["requests"]["storage"] == "1Gi"
    end

    test "honors an explicit access mode" do
      manifest =
        PersistentVolumeClaim.build_manifest("ns", "data", %{
          size: "1Gi",
          access_mode: "ReadWriteMany"
        })

      assert manifest["spec"]["accessModes"] == ["ReadWriteMany"]
    end
  end

  describe "create/4" do
    test "applies the PVC manifest" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert manifest["kind"] == "PersistentVolumeClaim"
        assert manifest["spec"]["resources"]["requests"]["storage"] == "10Gi"
        assert field_manager == "fluxvale"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "PersistentVolumeClaim"}} =
               PersistentVolumeClaim.create(%{}, "ns", "data", %{size: "10Gi"})
    end

    test "200 (resize apply) is still ok" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 200, body: :resized}} end)

      assert {:ok, :resized} = PersistentVolumeClaim.create(%{}, "ns", "data", %{size: "20Gi"})
    end

    test "transport failure maps to a connection error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               PersistentVolumeClaim.create(%{}, "ns", "data", %{size: "10Gi"})
    end
  end

  describe "get/3" do
    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} =
               PersistentVolumeClaim.get(%{}, "ns", "missing")
    end
  end

  describe "delete/3" do
    test "200 deletes synchronously" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200}} end)

      assert :ok = PersistentVolumeClaim.delete(%{}, "ns", "data")
    end

    test "404 is :not_found" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} =
               PersistentVolumeClaim.delete(%{}, "ns", "missing")
    end

    test "202 accepts asynchronous deletion (data goes with it)" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 202}} end)

      assert :ok = PersistentVolumeClaim.delete(%{}, "ns", "data")
    end
  end

  describe "status/3" do
    test "reads the PVC phase" do
      body = %{"status" => %{"phase" => "Bound"}}
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: body}} end)

      assert {:ok, "Bound"} = PersistentVolumeClaim.status(%{}, "ns", "data")
    end

    test "get errors propagate" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               PersistentVolumeClaim.status(%{}, "ns", "data")
    end

    test "a body with no status block reads as nil" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"kind" => "PersistentVolumeClaim"}}}
      end)

      assert {:ok, nil} = PersistentVolumeClaim.status(%{}, "ns", "data")
    end
  end

  describe "wait_for_bound/4" do
    test "status errors propagate immediately" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               PersistentVolumeClaim.wait_for_bound(%{}, "ns", "data", timeout_ms: 10)
    end

    test ":ok once the phase is Bound" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"status" => %{"phase" => "Bound"}}}}
      end)

      assert :ok = PersistentVolumeClaim.wait_for_bound(%{}, "ns", "data", timeout_ms: 10)
    end

    test "retries past a Pending poll, then succeeds" do
      # Mimic expects queue in call order: first poll Pending, second Bound
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"status" => %{"phase" => "Pending"}}}}
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"status" => %{"phase" => "Bound"}}}}
      end)

      assert :ok =
               PersistentVolumeClaim.wait_for_bound(%{}, "ns", "data",
                 timeout_ms: 500,
                 poll_interval_ms: 1
               )
    end

    test "times out with a structured timeout error while Pending" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"status" => %{"phase" => "Pending"}}}}
      end)

      assert {:error, %Error{reason: :timeout, message: msg}} =
               PersistentVolumeClaim.wait_for_bound(%{}, "ns", "data",
                 timeout_ms: 0,
                 poll_interval_ms: 1
               )

      assert msg =~ "Timeout waiting for PVC ns/data to be bound"
      assert msg =~ "Status: Pending"
    end
  end

  describe "upsert/4" do
    test "delegates to create (SSA idempotence)" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 201, body: :created}} end)

      assert {:ok, :created} = PersistentVolumeClaim.upsert(%{}, "ns", "app", %{size: "1Gi"})
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "v1"
      assert opts[:kind] == "PersistentVolumeClaim"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)
    PersistentVolumeClaim.get(%{}, "ns", "x")
  end
end

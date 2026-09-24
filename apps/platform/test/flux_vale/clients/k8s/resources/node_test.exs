defmodule FluxVale.Clients.K8s.Resources.NodeTest do
  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Node

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "parse_cpu/1" do
    test "plain cores" do
      parsed = Node.parse_cpu("4")
      assert Decimal.eq?(parsed, Decimal.new("4"))
    end

    test "fractional cores" do
      parsed = Node.parse_cpu("2.5")
      assert Decimal.eq?(parsed, Decimal.new("2.5"))
    end

    test "millicores divide to fractions" do
      parsed = Node.parse_cpu("500m")
      assert Decimal.eq?(parsed, Decimal.new("0.5"))
      parsed_1500 = Node.parse_cpu("1500m")
      assert Decimal.eq?(parsed_1500, Decimal.new("1.5"))
    end

    test "nil and garbage parse to zero (defensive, like parse_memory)" do
      parsed = Node.parse_cpu(nil)
      assert Decimal.eq?(parsed, Decimal.new(0))
      parsed_garbage = Node.parse_cpu("garbage")
      assert Decimal.eq?(parsed_garbage, Decimal.new(0))
    end
  end

  describe "parse_memory/1" do
    test "suffixed quantities convert to MiB" do
      assert Node.parse_memory("8192Mi") == 8192
      assert Node.parse_memory("8Gi") == 8192
      assert Node.parse_memory("1024Ki") == 1
      assert Node.parse_memory("1Ti") == 1_048_576
      assert Node.parse_memory("1Pi") == 1_073_741_824
      assert Node.parse_memory("1Ei") == 1_099_511_627_776
    end

    test "sub-MiB values truncate via integer division" do
      assert Node.parse_memory("512Ki") == 0
      assert Node.parse_memory("2048Ki") == 2
    end

    test "bare numbers are defensive MiB" do
      assert Node.parse_memory("512") == 512
    end

    test "nil and garbage parse to zero" do
      assert Node.parse_memory(nil) == 0
      assert Node.parse_memory("garbage") == 0
    end
  end

  describe "list/1" do
    test "returns the items of a NodeList" do
      expect(Kubereq, :list, fn _req ->
        {:ok, %{status: 200, body: %{"items" => [%{"kind" => "Node"}]}}}
      end)

      assert {:ok, [%{"kind" => "Node"}]} = Node.list(%{})
    end

    test "malformed 200 body is a validation error, not a from_response crash" do
      expect(Kubereq, :list, fn _req -> {:ok, %{status: 200, body: %{"unexpected" => 1}}} end)

      assert {:error, %Error{reason: :validation_error}} = Node.list(%{})
    end

    test "transport failure maps to a connection error" do
      expect(Kubereq, :list, fn _req -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} = Node.list(%{})
    end
  end

  describe "get/2" do
    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Node.get(%{}, "missing")
    end
  end

  describe "capacity/1" do
    test "aggregates allocatable CPU and memory across nodes in mixed units" do
      body = %{
        "items" => [
          %{"status" => %{"allocatable" => %{"cpu" => "4", "memory" => "8Gi"}}},
          %{"status" => %{"allocatable" => %{"cpu" => "500m", "memory" => "1024Mi"}}}
        ]
      }

      expect(Kubereq, :list, fn _req -> {:ok, %{status: 200, body: body}} end)

      assert {:ok, capacity} = Node.capacity(%{})
      assert Decimal.eq?(capacity.cpu, Decimal.new("4.5"))
      assert capacity.memory == 9216
    end

    test "empty cluster is zero capacity, not an error" do
      expect(Kubereq, :list, fn _req -> {:ok, %{status: 200, body: %{"items" => []}}} end)

      assert {:ok, capacity} = Node.capacity(%{})
      assert Decimal.eq?(capacity.cpu, Decimal.new(0))
      assert capacity.memory == 0
    end

    test "list errors propagate" do
      expect(Kubereq, :list, fn _req -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} = Node.capacity(%{})
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "v1"
      assert opts[:kind] == "Node"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _name -> {:ok, %{status: 404, body: %{}}} end)
    Node.get(%{}, "x")
  end
end

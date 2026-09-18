defmodule FluxVale.Clients.K8s.Resources.NodeTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s.Resources.Node

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
end

defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.PortsTest do
  @moduledoc false

  # ADR-0039 §3's port pool: lowest-free, bounded, and a clear refusal at
  # the ceiling rather than a silent spill into arbitrary ports.

  use ExUnit.Case, async: true

  alias FluxVale.Infrastructure.AccessProviders.Tailscale.Ports

  test "an empty gateway takes the first port" do
    assert {:ok, "8443"} = Ports.allocate([])
  end

  test "the next attach takes the next port" do
    assert {:ok, "8444"} = Ports.allocate(["8443"])
    assert {:ok, "8443"} = Ports.allocate(["8444"])
  end

  test "a freed port is reused — lowest free, not a counter" do
    assert {:ok, "8443"} = Ports.allocate(["8444", "8445"])
  end

  test "a gap in the middle is filled" do
    assert {:ok, "8444"} = Ports.allocate(["8443", "8445", "8446"])
  end

  test "the pool is exhausted, not spilled — a clear refusal at the ceiling" do
    taken = Enum.map(Ports.pool(), &Integer.to_string/1)

    assert {:error, :pool_exhausted} = Ports.allocate(taken)
  end

  test "the pool starts above the well-known range and is bounded" do
    pool = Ports.pool()

    assert Enum.min(pool) == 8443
    assert Enum.max(pool) == 8543
    assert Enum.count(pool) == 101
  end
end

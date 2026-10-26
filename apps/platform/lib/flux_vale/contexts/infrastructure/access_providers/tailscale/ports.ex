defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.Ports do
  @moduledoc """
  Allocates a gateway's per-app serve ports (ADR-0039 §3).

  The pool starts at 8443 and moves up — deliberately above the
  well-known range and away from serve's common 443/80, so an owner's
  other tailnet services never collide and the port reads as
  "FluxVale's app" in a URL. One port per attached instance, and a port
  is never reused while its route row lives (`AccessRoute`'s
  `unique_route_key` makes a duplicate a database error, not a silent
  cross-tenant leak).

  Allocation is "lowest free in the pool", not "next counter": a detach
  frees its port for the next attach, which keeps URLs short and the
  config small. Deterministic from the routes in hand, so a re-apply
  after a crash converges on the same assignment (the operator owners'
  idempotence stance).
  """

  @first_port 8443
  @last_port 8543

  @typedoc "A port from the pool, as the string `AccessRoute.route_key` stores"
  @type port_key :: String.t()

  @doc """
  The lowest port in the pool not in `taken`. `{:error, :pool_exhausted}`
  past the ceiling — 101 attached instances on one gateway is far past
  the B1 shape, and silently spilling into arbitrary ports would be
  worse than a clear refusal.
  """
  @spec allocate([port_key()]) :: {:ok, port_key()} | {:error, :pool_exhausted}
  def allocate(taken) do
    used = MapSet.new(taken)
    pool = @first_port..@last_port
    free = Enum.find(pool, fn port -> not MapSet.member?(used, Integer.to_string(port)) end)

    case free do
      nil -> {:error, :pool_exhausted}
      port -> {:ok, Integer.to_string(port)}
    end
  end

  @doc "The pool bounds — the attach error's copy and the tests pin them."
  @spec pool() :: Range.t()
  def pool, do: @first_port..@last_port
end

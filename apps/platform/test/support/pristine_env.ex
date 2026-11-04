defmodule FluxVale.TestSupport.PristineEnv do
  @moduledoc """
  Boot-time snapshots of app-env blocks, captured in test_helper BEFORE
  `ExUnit.start/1` — the one moment no async test can be interleaved
  (owner ruling: all tests stay `async: true`, isolation beats
  serialization).

  Tests that certify SHIPPED configuration (the backup chain
  invariant, #222) must not consult the runtime app env: async tests
  may legitimately mutate a block mid-run (a restore test's
  zero-scale-down timeout — capture-and-restore compliant, but visible
  to any concurrent reader), and the runtime value would witness the
  mutation. A boot snapshot cannot: `:persistent_term` is outside every
  test's reach.

  Snapshot more blocks the same way — one `capture/1` line in
  test_helper, one `fetch!/1` at the reader.
  """

  @doc "Freezes the current value of a `:flux_vale` config block at boot."
  @spec capture(atom()) :: :ok
  def capture(block) do
    {:ok, value} = Application.fetch_env(:flux_vale, block)
    :persistent_term.put({__MODULE__, block}, value)
    :ok
  end

  @doc "Reads a frozen block. Raises when the block was never captured."
  @spec fetch!(atom()) :: term()
  def fetch!(block) do
    :persistent_term.get({__MODULE__, block}, nil) ||
      raise ArgumentError,
            "no pristine snapshot for #{inspect(block)} — capture it in test_helper"
  end
end

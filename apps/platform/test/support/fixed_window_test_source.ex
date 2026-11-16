defmodule FluxVale.TestSupport.FixedWindowTestSource do
  @moduledoc """
  A #510 engine source for the conformance suite: one fixed bucket and
  its own table, so the engine's owner lifecycle can be exercised
  (start/stop/restart, the fail-open arm) without touching the
  app-supervised surfaces.
  """

  @behaviour FluxValeWeb.Plugs.FixedWindow

  @table __MODULE__.Windows

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec bucket(atom()) :: %{window_seconds: pos_integer(), max_requests: pos_integer()}
  def bucket(:probe), do: %{window_seconds: 86_400, max_requests: 2}
  def bucket(other), do: raise(ArgumentError, "no such bucket: #{inspect(other)}")

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec max_rows() :: pos_integer()
  def max_rows, do: 100_000

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec max_window_seconds() :: pos_integer()
  def max_window_seconds, do: 86_400
end

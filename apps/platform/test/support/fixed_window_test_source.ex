defmodule FluxVale.TestSupport.FixedWindowTestSource do
  @moduledoc """
  A #510 engine source for the conformance suite: one fixed bucket and
  its own table, so the engine's owner lifecycle (start/stop/restart,
  the fail-open arm) and the hard row cap can be exercised without
  touching the app-supervised surfaces. `max_rows` reads app env on
  this module (capture-and-restore) so a test can stage a small cap;
  everything else is fixed.
  """

  @behaviour FluxValeWeb.Plugs.FixedWindow

  @table __MODULE__.Windows
  @default_max_rows 100_000

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
  def max_rows do
    config = Application.get_env(:flux_vale, __MODULE__, [])

    case Keyword.get(config, :max_rows, @default_max_rows) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} max_rows must be a positive integer, got: #{inspect(other)}"
    end
  end

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec max_window_seconds() :: pos_integer()
  def max_window_seconds, do: 86_400
end

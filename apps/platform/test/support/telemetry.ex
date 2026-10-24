defmodule FluxVale.TestSupport.Telemetry do
  @moduledoc """
  Capture-and-restore telemetry events (#232): attaches one forwarding
  handler for the given events, delivers them to the test process as
  `{:telemetry_event, event, measurements, metadata}` messages, and
  detaches on exit — Tracing's discipline for the metrics pillar.

  `async: true`-safe: the unique handler id never collides, and only
  the owning process receives the sends.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Captures `events` (a `:telemetry.attach_many/4` event list) for the
  duration of the test.
  """
  @spec capture_events([:telemetry.event_name()]) :: :ok
  def capture_events(events) do
    test_pid = self()
    handler_id = {__MODULE__, System.unique_integer()}

    :telemetry.attach_many(handler_id, events, &forward/4, %{test_pid: test_pid})

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp forward(event, measurements, metadata, %{test_pid: test_pid}) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end
end

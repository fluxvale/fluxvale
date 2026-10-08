defmodule FluxVale.TestSupport.Tracing do
  @moduledoc """
  Span-observation for tests: points the running batch processor's
  exporter at `:otel_exporter_pid`, so every exported span arrives as a
  `{:span, span}` message in the given pid's mailbox.

  No application restart — the SDK caches per-scope tracers in
  `persistent_term`, and a restarted provider would leave lib-module
  tracers on the boot-time (exporter-less) processors.

  The swap is VM-global state, so callers must be `async: false` (ExUnit
  runs those modules exclusively). Spans buffered in the shared batch
  table outlive a swap, so the matchers scope on a unique attribute (an
  instance id), never just the span name.
  """

  import ExUnit.Assertions

  require Record

  # include/ isn't copied into _build for rebar3 deps — read it from the
  # dep tree (mix test always runs with the app dir as cwd).
  Record.defrecordp(
    :span,
    Record.extract(:span, from: "deps/opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :attributes,
    Record.extract(:attributes, from: "deps/opentelemetry_api/src/otel_attributes.erl")
  )

  @doc """
  Routes exported spans to `pid` for the duration of the test. Returns
  :ok — nothing to capture, the batch processor swap is undone by
  `restore/0`.
  """
  @spec export_spans_to(pid()) :: :ok
  def export_spans_to(pid) do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, pid)
  end

  @doc """
  Ends the exporter swap: the pid exporter then points at this
  short-lived runner process, whose exit stops delivery — functionally
  the boot-time no-op. (A literal :none here would log a misleading
  "exporter not found" warning from the SDK.)
  """
  @spec restore() :: :ok
  def restore do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
  end

  @doc """
  The span named `name` whose `attribute_key` is `attribute_value` —
  the batch is force-flushed and re-flushed between receive windows
  (a flush can race the span's insert into the export table).
  Non-matching spans are consumed.
  """
  @spec span_matching(binary() | atom(), term(), term()) :: tuple()
  def span_matching(name, attribute_key, attribute_value),
    do: span_matching(name, attribute_key, attribute_value, 5)

  def span_matching(name, attribute_key, attribute_value, attempts) do
    flush_batch()

    receive do
      {:span, span(name: ^name) = span_record} ->
        if attribute_map(span_record)[attribute_key] == attribute_value do
          span_record
        else
          span_matching(name, attribute_key, attribute_value, attempts)
        end
    after
      400 ->
        if attempts > 1 do
          span_matching(name, attribute_key, attribute_value, attempts - 1)
        else
          flunk("no #{name} span with #{inspect(attribute_key)} = #{inspect(attribute_value)}")
        end
    end
  end

  @doc """
  No span named `name` with `attribute_key` = `attribute_value` exports
  within `timeout` ms — concurrent same-name spans are consumed.
  """
  @spec refute_span_matching(binary() | atom(), term(), term(), non_neg_integer()) :: :ok
  def refute_span_matching(name, attribute_key, attribute_value, timeout \\ 300) do
    flush_batch()

    receive do
      {:span, span(name: ^name) = span_record} ->
        if attribute_map(span_record)[attribute_key] == attribute_value do
          flunk("expected no #{name} span for #{inspect(attribute_value)}")
        end

        refute_span_matching(name, attribute_key, attribute_value, timeout)

      _other_span ->
        refute_span_matching(name, attribute_key, attribute_value, timeout)
    after
      timeout ->
        :ok
    end
  end

  @doc """
  The raw key/value attribute map of an exported span record.
  """
  @spec attribute_map(tuple()) :: map()
  def attribute_map(span_record) do
    span_record |> span(:attributes) |> attributes(:map)
  end

  defp flush_batch do
    :otel_batch_processor.force_flush(%{reg_name: :otel_batch_processor_global})
  end
end

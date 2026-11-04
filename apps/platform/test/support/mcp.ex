defmodule FluxVale.TestSupport.Mcp do
  @moduledoc """
  The /mcp transport harness for the MCP tests (#361): stateless
  2026-07-28 POSTs through the app router, with the routing headers
  the protocol requires (Mcp-Method, and Mcp-Name where the body
  names something), and the SSE response parser — a modern POST's
  JSON-RPC result arrives as `event: message` frames.
  """

  @endpoint FluxValeWeb.Endpoint

  @proto "2026-07-28"

  @doc """
  POSTs a JSON-RPC request to /mcp as a 2026-07-28 client would.
  `pat` rides as the bearer; pass `authorization: :none` to send a
  forged header (the invalid-token proofs) and nil for no header.
  """
  def post(conn, pat, method, params, opts \\ [])

  def post(conn, pat, method, params, opts) do
    if Keyword.get(opts, :legacy, false) do
      legacy_post(conn, pat, method, params, opts)
    else
      modern_post(conn, pat, method, params, opts)
    end
  end

  # A legacy client's POST: no per-request _meta, a legacy protocol
  # version header (or none at all).
  defp legacy_post(conn, pat, method, params, opts) do
    header = Keyword.get(opts, :protocol_version, "2025-06-18")

    proto_headers =
      if header == :none do
        []
      else
        [{"mcp-protocol-version", header}]
      end

    base_post(conn, pat, method, params,
      proto_headers: proto_headers,
      extra_params: %{},
      id: Keyword.get(opts, :id, 1)
    )
  end

  defp modern_post(conn, pat, method, params, opts) do
    # 2026-07-28 validates the protocol version from BOTH the header
    # and the per-request `_meta`, and the meta must also carry the
    # client's capabilities object — a stateless POST carries all three.
    # `:capabilities` deepens the defaults (the confirmation tests
    # declare elicitation support — an input_required result refuses
    # without it).
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @proto,
      "io.modelcontextprotocol/clientCapabilities" =>
        Map.merge(%{}, Keyword.get(opts, :capabilities, %{}))
    }

    base_post(conn, pat, method, params,
      proto_headers: [{"mcp-protocol-version", @proto}],
      extra_params: %{"_meta" => meta},
      id: Keyword.get(opts, :id, 1)
    )
  end

  defp base_post(conn, pat, method, params, opts) do
    name_header =
      case params do
        %{"name" => name} when is_binary(name) -> [{"mcp-name", name}]
        _other -> []
      end

    auth_header =
      case Keyword.get(opts, :authorization, if(pat, do: :bearer)) do
        :bearer -> [{"authorization", "Bearer " <> pat}]
        {:bearer, value} -> [{"authorization", "Bearer " <> value}]
        _absent -> []
      end

    headers =
      [
        {"accept", "application/json, text/event-stream"},
        {"content-type", "application/json"},
        {"mcp-method", method}
      ] ++
        Keyword.fetch!(opts, :proto_headers) ++
        name_header ++ auth_header

    params = Map.merge(params, Keyword.fetch!(opts, :extra_params))

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => Keyword.fetch!(opts, :id),
        "method" => method,
        "params" => params
      })

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc ->
        Plug.Conn.put_req_header(acc, name, value)
      end)

    dispatch_off_test_process(conn, path: "/mcp", body: body)
  end

  # Phantom's response stream turns the transport process into a
  # gen_server (`Session.start_loop` → enter_loop) — that requires a
  # proc_lib-started process, and ConnTest's dispatch runs in the test
  # process. The dispatch therefore runs in a spawned proc_lib runner;
  # the SQL sandbox connection is lent to it explicitly (Mimic stubs
  # stay per-process by design: fixtures run in the test process, the
  # tool handlers read real rows).
  defp dispatch_off_test_process(conn, dispatch_opts) do
    parent = self()
    ref = make_ref()

    runner =
      :proc_lib.spawn(fn ->
        receive do
          :dispatch ->
            Ecto.Adapters.SQL.Sandbox.allow(FluxVale.Repo, parent, self())

            result =
              try do
                Phoenix.ConnTest.dispatch(
                  conn,
                  @endpoint,
                  :post,
                  dispatch_opts[:path],
                  dispatch_opts[:body]
                )
              rescue
                exception -> {:raised, exception, __STACKTRACE__}
              end

            send(parent, {ref, result})
        end
      end)

    send(runner, :dispatch)

    receive do
      {^ref, %Plug.Conn{} = conn} ->
        conn

      {^ref, {:raised, exception, stacktrace}} ->
        reraise exception, stacktrace
    after
      15_000 ->
        raise "MCP dispatch timed out after 15s"
    end
  end

  @doc "Lists tools through the transport."
  def list_tools(conn, pat, opts \\ []) do
    post(conn, pat, "tools/list", %{}, opts)
  end

  @doc """
  Calls one tool through the transport. The confirmation tools'
  follow-up call rides `:input_responses` (the answers keyed by the
  input request) and `:request_state` (the encrypted blob from the
  `input_required` result) — both land at params level, exactly where
  the spec puts them. `:capabilities` deepens the client capability
  object (`%{"elicitation" => %{}}` for the confirm round-trips).
  """
  def call_tool(conn, pat, name, args, opts \\ []) do
    params =
      %{"name" => name, "arguments" => args}
      |> maybe_put_param("inputResponses", opts[:input_responses])
      |> maybe_put_param("requestState", opts[:request_state])

    post_opts =
      opts
      |> Keyword.take([:legacy, :protocol_version, :authorization, :id, :capabilities])
      |> Keyword.put(:capabilities, Keyword.get(opts, :capabilities, %{}))

    post(conn, pat, "tools/call", params, post_opts)
  end

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  @doc """
  The decoded JSON-RPC messages from the SSE stream — one per
  `data:` frame.
  """
  def sse_messages(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      frame
      |> String.split("\n", trim: true)
      |> Enum.find_value([], fn line ->
        if String.starts_with?(line, "data: "), do: [String.slice(line, 6..-1//1)]
      end)
    end)
    |> Enum.map(&Jason.decode!/1)
  end

  @doc "The single JSON-RPC result of a successful POST."
  def result(conn) do
    case sse_messages(conn) do
      [%{"result" => result}] ->
        result

      other ->
        raise "expected one JSON-RPC result frame, got: #{inspect(other)} — " <>
                "status #{conn.status}, body #{inspect(binary_part(conn.resp_body, 0, min(byte_size(conn.resp_body), 2000)))}"
    end
  end

  @doc "The structured payload of a tool result."
  def structured(conn) do
    result(conn)["structuredContent"]
  end

  @doc "The tool-error text (isError results carry one text block)."
  def error_text(conn) do
    %{"isError" => true, "content" => [%{"text" => text}]} = result(conn)
    text
  end
end

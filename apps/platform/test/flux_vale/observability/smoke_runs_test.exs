defmodule FluxVale.Observability.SmokeRunsTest do
  @moduledoc """
  The console smoke widget's data source (#702, W2): the public runs
  API mapping, the unreachable arms (non-200, transport, raise, malformed
  body), the TTL cache, and the safety wrapper's pass-through.

  async: false — tests manipulate the app env, the Req.Test shared mode,
  and the app tree's named SmokeRuns server.
  """

  use ExUnit.Case, async: false

  alias FluxVale.Observability.SmokeRuns

  setup do
    original_options = Application.get_env(:flux_vale, :smoke_runs_req_options)
    Application.put_env(:flux_vale, :smoke_runs_req_options, plug: {Req.Test, :smoke_runs})

    on_exit(fn ->
      Application.put_env(:flux_vale, :smoke_runs_req_options, original_options)
    end)

    previous_state = :sys.get_state(SmokeRuns)

    on_exit(fn ->
      :sys.replace_state(SmokeRuns, fn _state -> previous_state end)
    end)

    :sys.replace_state(SmokeRuns, fn _state ->
      %{computed_at: nil, result: {:error, :unreachable}}
    end)

    # The request runs inside the named GenServer, not the test process —
    # the stubs must be shared for the server to find them.
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn -> Req.Test.set_req_test_to_private(%{}) end)

    :ok
  end

  test "maps the runs API shape" do
    Req.Test.stub(:smoke_runs, fn conn ->
      Req.Test.json(conn, %{
        "workflow_runs" => [
          %{
            "conclusion" => "success",
            "status" => "completed",
            "created_at" => "2026-11-11T06:17:02Z",
            "html_url" => "https://example.com/run/1"
          }
        ]
      })
    end)

    assert {:ok, %{runs: [run], fetched_at: %DateTime{}}} = SmokeRuns.latest()
    assert run.conclusion == "success"
    assert run.status == "completed"
    assert run.created_at == "2026-11-11T06:17:02Z"
    assert run.url == "https://example.com/run/1"
  end

  test "a non-200 answers unreachable" do
    Req.Test.stub(:smoke_runs, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert SmokeRuns.latest() == {:error, :unreachable}
  end

  test "a transport error answers unreachable" do
    Req.Test.stub(:smoke_runs, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert SmokeRuns.latest() == {:error, :unreachable}
  end

  test "a raising stub answers unreachable, never a crash" do
    Req.Test.stub(:smoke_runs, fn _conn -> raise "boom" end)

    assert SmokeRuns.latest() == {:error, :unreachable}

    # An exit in the request path is the same unreachable state — the
    # catch arm, not a crashed server.
    Req.Test.stub(:smoke_runs, fn _conn -> exit(:boom) end)

    assert SmokeRuns.latest() == {:error, :unreachable}

    install_success_stub()

    # The server survived both failures and serves the next good fetch.
    assert {:ok, %{runs: [_run]}} = SmokeRuns.latest()
  end

  test "a 200 with a malformed body answers unreachable" do
    Req.Test.stub(:smoke_runs, fn conn -> Req.Test.json(conn, %{"nope" => true}) end)

    assert SmokeRuns.latest() == {:error, :unreachable}
  end

  test "the TTL caches one fetch" do
    original_ttl = Application.get_env(:flux_vale, :smoke_runs_ttl_seconds, 60)
    Application.put_env(:flux_vale, :smoke_runs_ttl_seconds, 3600)

    on_exit(fn ->
      Application.put_env(:flux_vale, :smoke_runs_ttl_seconds, original_ttl)
    end)

    counter = :counters.new(1, [])

    Req.Test.stub(:smoke_runs, fn conn ->
      :counters.add(counter, 1, 1)
      success_json(conn)
    end)

    assert {:ok, first} = SmokeRuns.latest()
    assert {:ok, second} = SmokeRuns.latest()
    assert :counters.get(counter, 1) == 1
    assert first.fetched_at == second.fetched_at

    # Lapse the TTL: the next read refills.
    Application.put_env(:flux_vale, :smoke_runs_ttl_seconds, 0)

    assert {:ok, _third} = SmokeRuns.latest()
    assert :counters.get(counter, 1) == 2
  end

  test "latest_safe/0 passes the success through" do
    install_success_stub()

    assert {:ok, %{runs: [_run]}} = SmokeRuns.latest_safe()
  end

  defp install_success_stub do
    Req.Test.stub(:smoke_runs, &success_json/1)
  end

  defp success_json(conn) do
    Req.Test.json(conn, %{
      "workflow_runs" => [
        %{
          "conclusion" => "success",
          "status" => "completed",
          "created_at" => "2026-11-11T06:17:02Z",
          "html_url" => "https://example.com/run/1"
        }
      ]
    })
  end
end

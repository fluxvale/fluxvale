defmodule FluxVale.Observability.SmokeRuns do
  @moduledoc """
  The console smoke widget's data source (#702, ADR-0050 D3/W2): the
  latest default-branch runs of the public smoke workflow, read
  server-side through `Req`.

  The source is the public runs API of `fluxvale/fluxvale` — an
  unauthenticated read against a public repo, cached 60 seconds so page
  mounts share one fetch (the unauthenticated budget is 60 requests an
  hour). At saturation (a mount a minute) the 60s cache consumes the
  whole 60-request/hour quota for the egress IP; a saturated budget
  answers 403 and the widget renders Unreachable. Any failure answers
  `{:error, :unreachable}` and the widget says so; it never guesses a
  verdict.

  Tier-1 boundary: the Grafana heartbeat series and synthetics stay
  Grafana-side. This widget is the workflow's own verdict — the same
  runs GitHub reports — not a synthetic probe.
  """

  use GenServer

  @runs_url "https://api.github.com/repos/fluxvale/fluxvale/actions/workflows/smoke.yml/runs?branch=main&per_page=5"

  @type run :: %{
          conclusion: String.t() | nil,
          status: String.t(),
          created_at: String.t() | nil,
          url: String.t() | nil
        }

  @type result :: {:ok, %{runs: [run()], fetched_at: DateTime.t()}} | {:error, :unreachable}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{computed_at: nil, result: {:error, :unreachable}}}
  end

  @impl GenServer
  def handle_call(:latest, _from, state) do
    state = refresh(state)
    {:reply, state.result, state}
  end

  @doc """
  The cached latest runs — `{:ok, %{runs: [...], fetched_at: ...}}` or
  `{:error, :unreachable}`.
  """
  @spec latest() :: result()
  def latest do
    GenServer.call(__MODULE__, :latest, 10_000)
  end

  @doc """
  `latest/0` behind the widget's safety wrapper: any crash or exit
  answers `{:error, :unreachable}` — a derived widget must never take
  the console down.
  """
  @spec latest_safe() :: result()
  def latest_safe do
    latest()
  rescue
    # coveralls-ignore-start - both arms answer unreachable so the widget
    # can't take the console down; the named server is alive under the app
    # tree for the whole suite (a call exits only in the supervisor's
    # restart gap, which no test can hold open).
    _exception ->
      {:error, :unreachable}
  catch
    :exit, _reason ->
      {:error, :unreachable}
      # coveralls-ignore-stop
  end

  defp refresh(state) do
    if fresh?(state) do
      state
    else
      %{computed_at: DateTime.utc_now(), result: fetch()}
    end
  end

  defp fresh?(%{computed_at: nil}), do: false

  defp fresh?(%{computed_at: computed_at}) do
    ttl = Application.get_env(:flux_vale, :smoke_runs_ttl_seconds, 60)
    DateTime.diff(DateTime.utc_now(), computed_at, :second) < ttl
  end

  # The 60s cache is the retry: one attempt per window keeps GitHub reads
  # bounded; a failure is the widget's unreachable state, never a crash.
  defp fetch do
    options =
      [
        url: @runs_url,
        headers: [accept: "application/vnd.github+json"],
        # Bound the TCP connect too — Mint's 30s default could stall a mount.
        connect_options: [timeout: 5_000],
        receive_timeout: 5_000,
        retry: false
      ] ++ Application.get_env(:flux_vale, :smoke_runs_req_options, [])

    case Req.request(options) do
      {:ok, %Req.Response{status: 200, body: %{"workflow_runs" => runs}}} when is_list(runs) ->
        {:ok, %{runs: Enum.map(runs, &map_run/1), fetched_at: DateTime.utc_now()}}

      _other ->
        {:error, :unreachable}
    end
  rescue
    _exception ->
      {:error, :unreachable}
  catch
    # An exit raised inside the request path (e.g. exit/1 in a plug) is
    # the same unreachable state as a raise; a real kill is the
    # supervisor's concern.
    :exit, _reason ->
      {:error, :unreachable}
  end

  defp map_run(run) do
    %{
      conclusion: run["conclusion"],
      status: run["status"],
      created_at: run["created_at"],
      url: run["html_url"]
    }
  end
end

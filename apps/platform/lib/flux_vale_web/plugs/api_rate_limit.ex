defmodule FluxValeWeb.Plugs.ApiRateLimit do
  @moduledoc """
  The per-token fixed-window rate limit on `/api/v1` (#360 slice 3,
  ADR-0019 §4: agent-driven actions get rate limits "like any other
  API client").

  Applies only to PAT-authenticated calls (`conn.assigns.api_pat`,
  set by Authenticate): session calls pass untouched, and
  unauthenticated ones never arrive (RequireActor already 401'd).
  Mounted after AuthorizeApiScopes, a scope-refused (403) call never
  reaches it either — a deliberate stance: this limiter meters API
  *use*; unauthenticated and scope-denied floods cost one indexed
  SHA-256 lookup each and are the edge proxy's concern, not the
  meter's.

  Over the limit: 429 with a JSON:API error document byte-matching
  AuthorizeApiScopes' rendering, plus a `Retry-After` header —
  integer seconds until the window resets.

  Every PAT call that reaches this plug counts, including the ones
  refused here: a hammering client never earns uncounted requests.

  ## Configuration

  Application env on this module — both runtime-readable, so any
  environment can override (test.exs sets small numbers for the
  hammer suites). Defaults are the generous posture: a human's
  scripting bursts through, only a runaway loop trips it.

      config :flux_vale, FluxValeWeb.Plugs.ApiRateLimit,
        window_seconds: 60,
        max_requests: 300
  """

  import Plug.Conn

  alias FluxVale.Api

  @default_window_seconds 60
  @default_max_requests 300
  @over_limit_detail "this token has exceeded the API rate limit"

  @doc false
  @spec init(keyword) :: keyword
  def init(opts), do: opts

  @doc """
  Counts and gates PAT-authenticated calls; everything else passes
  through untouched.
  """
  @spec call(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.assigns[:api_pat] do
      nil -> conn
      pat -> gate(conn, pat)
    end
  end

  # Increment first, then check: the refused request still counts, so
  # the store's total is the true number of calls made.
  defp gate(conn, pat) do
    window_seconds = window_seconds()
    now = DateTime.utc_now()
    started_at = window_start(now, window_seconds)

    count = Api.bump_request_window(pat.id, started_at)

    if count > max_requests() do
      reset_in = retry_after(now, started_at, window_seconds)
      too_many_requests(conn, reset_in)
    else
      conn
    end
  end

  # Floor bucketing: a request at epoch second s belongs to the
  # window starting at div(s, window) * window. Windows stay aligned
  # to the clock (Retry-After is just the distance to the next
  # boundary), and the write needs no read first — the alternative,
  # tumbling windows anchored on the first request, would.
  defp window_start(now, window_seconds) do
    epoch = DateTime.to_unix(now)
    bucket = div(epoch, window_seconds) * window_seconds
    DateTime.from_unix!(bucket)
  end

  # Integer seconds until the window resets, floored at 1: a request
  # in the last second of its window still owes a full retry second —
  # a computed 0 would invite the client's busy-loop.
  defp retry_after(now, started_at, window_seconds) do
    window_end = DateTime.add(started_at, window_seconds, :second)
    max(DateTime.diff(window_end, now), 1)
  end

  defp window_seconds, do: config!(:window_seconds, @default_window_seconds)

  defp max_requests, do: config!(:max_requests, @default_max_requests)

  # Fail at the config boundary, not mid-request: a string limit
  # (term ordering: numbers < binaries) would silently disable the
  # check, and a zero window would ArithmeticError every PAT call —
  # the runtime_config.exs posture for malformed env.
  defp config!(key, default) do
    case Application.get_env(:flux_vale, __MODULE__, [])[key] do
      nil ->
        default

      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} #{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  # AuthorizeApiScopes' exact rendering posture: JSON:API error
  # document, bare media type with no charset (byte-identical to
  # every other /api/v1 error).
  defp too_many_requests(conn, reset_in) do
    body =
      Jason.encode!(%{
        errors: [%{status: "429", title: "Too Many Requests", detail: @over_limit_detail}]
      })

    conn
    |> put_resp_header("retry-after", Integer.to_string(reset_in))
    |> put_resp_content_type("application/vnd.api+json", nil)
    |> resp(429, body)
    |> halt()
  end
end

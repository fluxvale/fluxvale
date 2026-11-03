defmodule FluxVale.Api.OpenApiDump do
  @moduledoc """
  The committed OpenAPI artifact for `/api/v1` (#360 slice 4,
  [ADR-0019 §2](../../../../../docs/adr/00019-machine-first-api-cli-mcp.md)):
  the spec rendered offline from compiled Ash resources — no server,
  no Repo — as the build input for CLI client generation.

  `render/0` rides `FluxValeWeb.AshJsonApiRouter.spec/0`, the render
  the dep generates on the router — the same
  `AshJsonApi.OpenApi.spec/2` call `GET /api/v1/open_api` rides, minus
  the request: the endpoint-derived `servers` entry stays empty in the
  artifact (deployment URLs are not contract surface). Both paths pin
  the render's module loads first (`pin_render_modules/0` — the
  `/api/v1` scope plug calls it too), so a cold server serves exactly
  what the artifact holds.

  Bytes are diff-stable: keys sorted at every level, so the artifact
  changes only when the contract does.
  """

  alias FluxValeWeb.AshJsonApiRouter

  @artifact "open_api.json"

  # Modules the render may probe but never load itself (see
  # pin_render_modules/0). The app's own types/calculations live in
  # :flux_vale; the shared expr-calculation module in :ash. The list is
  # MAINTENANCE-BEARING: a future calculation whose module lives in
  # another app (an :ash_postgres/:ash_authentication helper) is probed
  # just as coldly — its app belongs here, or the omission returns.
  @preload_apps [:flux_vale, :ash]

  # :persistent_term flag for the once-per-VM pin (read on every
  # /api/v1 request through the scope plug — one lookup after boot).
  @pinned_key {__MODULE__, :render_modules_pinned}

  @doc """
  Default artifact path — `priv/open_api.json` of the `:flux_vale` OTP
  app (under mix, the committed `apps/platform/priv` via the build
  symlink; in a release, whatever ships with the app).
  """
  @spec default_path() :: Path.t()
  def default_path do
    Application.app_dir(:flux_vale, Path.join("priv", @artifact))
  end

  @doc """
  The offline spec render as deterministic JSON bytes (pretty, keys
  sorted at every level).
  """
  @spec render() :: binary()
  def render do
    pin_render_modules()

    spec = AshJsonApiRouter.spec()

    json = Jason.encode!(spec)

    json
    |> Jason.decode!()
    |> encode("")
    |> IO.iodata_to_binary()
  end

  # ash_json_api 1.7.1 decides calculation filter schemas with
  # `function_exported?(module, :expression, 2)` — and that probe does
  # NOT load the module. Unchecked, the spec's content depends on what
  # prior boot activity happened to load: a cold `mix run` omits
  # `user-filter-email`, a warmed test VM includes it. Loading these
  # apps' modules first pins the render to compiled truth, not boot
  # accident — on BOTH the offline render (above) and the served one
  # (the /api/v1 scope plug), so the twin can't fork from the artifact.
  #
  # Once per VM; a concurrent double-run is two idempotent loads.
  @doc """
  Loads every module of `@preload_apps` — once per VM — pinning the
  render to compiled truth (the comment above explains the probe).
  `render/0` and the `/api/v1` scope plug both call it.
  """
  @spec pin_render_modules() :: :ok
  def pin_render_modules do
    if :persistent_term.get(@pinned_key, false) do
      :ok
    else
      for app <- @preload_apps, modules = Application.spec(app, :modules), is_list(modules) do
        Enum.each(modules, &Code.ensure_loaded/1)
      end

      :persistent_term.put(@pinned_key, true)
      :ok
    end
  end

  # `spec/0` returns `%OpenApiSpex.OpenApi{}` with structs nested all
  # the way down — and a struct IS a map to the clause below, which
  # would serialize it field-by-field, `__struct__` included. The
  # round trip rides Jason's struct encoders once and lands plain
  # maps/lists/scalars for this printer, which makes the bytes
  # diff-stable: every object's keys sorted (binary order on the
  # now-string keys), so the artifact changes only when the contract
  # does, never with VM map order. Scalars ride Jason for escaping.
  defp encode(object, indent) when is_map(object) do
    inner = indent <> "  "

    object
    |> Enum.sort()
    |> Enum.map_intersperse(",\n", fn {key, value} ->
      [inner, Jason.encode!(key), ": ", encode(value, inner)]
    end)
    |> wrap("{", "}", indent)
  end

  defp encode(array, indent) when is_list(array) do
    inner = indent <> "  "

    array
    |> Enum.map_intersperse(",\n", &[inner, encode(&1, inner)])
    |> wrap("[", "]", indent)
  end

  defp encode(scalar, _indent), do: Jason.encode!(scalar)

  # Empty collections print compact (`{}` / `[]`); non-empty ones open
  # on the next line at `indent`, closing aligned with their opener.
  defp wrap([], open, close, _indent), do: [open, close]

  defp wrap(body, open, close, indent) do
    [open, "\n", body, "\n", indent, close]
  end
end

defmodule FluxValeWeb.Plugs.PinOpenApiRender do
  @moduledoc """
  Pins the OpenAPI render's module loads for the `/api/v1` scope
  (#360 slice 4) — the served twin's half of the artifact-equality
  guarantee: without the pin, the spec a cold server serves at
  `GET /api/v1/open_api` depends on what happened to boot before it,
  not on the compiled contract.

  Why module loads matter at all — the `function_exported?/3` probe
  and its cold-boot omission — lives canonically in
  `FluxVale.Api.OpenApiDump.pin_render_modules/0`'s comment; this plug
  just applies that pin per request (once per VM, so it costs one
  lookup after the first).
  """

  alias FluxVale.Api.OpenApiDump

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    OpenApiDump.pin_render_modules()
    conn
  end
end

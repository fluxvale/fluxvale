defmodule FluxValeWeb.Plugs.PutPatScopesInAshContext do
  @moduledoc """
  Carries the calling PAT's scopes into the Ash request context (#484):
  Authenticate resolves the bearer token (`conn.assigns.api_pat`), and
  ash_json_api reads its context per request — this plug is the bridge
  between the two.

  The consumer is /me's token introspection (W2b: MCP tool filtering
  needs the wire to carry scope knowledge — write domains are not
  probeable the way read domains are). Scopes are a property of the
  token, not the user record, so they render through request-scoped
  meta, never a User field. A session-authenticated caller has no PAT
  and gets no context entry — the honest omission, not an empty list.
  """

  alias FluxVale.Api.Scopes

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc """
  Sets the calling PAT's scopes into the Ash request context (under
  `FluxVale.Api.Scopes.pat_scopes_context_key/0`); everyone else passes
  through untouched. The callback form MERGES into any existing context —
  the map form (`set_context/2`) replaces the whole map and would
  silently wipe a future neighbor's entry.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.assigns[:api_pat] do
      nil ->
        conn

      pat ->
        key = Scopes.pat_scopes_context_key()

        Ash.PlugHelpers.update_context(conn, fn context ->
          Map.merge(context || %{}, %{key => pat.scopes})
        end)
    end
  end
end

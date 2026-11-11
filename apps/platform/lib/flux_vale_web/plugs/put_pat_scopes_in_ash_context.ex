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

  The same PAT branch also marks the request PROCESS as a machine-API
  call (#644, ADR-0047): the blanket platform-admin bypass's refusal
  condition reads that mark, and the process is the only rung a
  NESTED action call cannot drop (a generic action's inner get_by_id
  re-reads with fresh options — the context does not ride it, the
  process does). Same mechanism, same key, one owner:
  `FluxVale.Checks.CallOutsideMachineApi.mark_process!/0` — the only
  boundary writer since the Phantom endpoint retired (ADR-0019 Am. 5).
  """

  alias FluxVale.Api.Scopes
  alias FluxVale.Checks.CallOutsideMachineApi

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc """
  Sets the calling PAT's scopes into the Ash request context (under
  `FluxVale.Api.Scopes.pat_scopes_context_key/0`) and marks the request
  process as a machine-API call; everyone else passes through
  untouched. The callback form MERGES into any existing context — the
  map form (`set_context/2`) replaces the whole map and would silently
  wipe a future neighbor's entry.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.assigns[:api_pat] do
      nil ->
        conn

      pat ->
        CallOutsideMachineApi.mark_process!()

        key = Scopes.pat_scopes_context_key()

        Ash.PlugHelpers.update_context(conn, fn context ->
          Map.merge(context || %{}, %{key => pat.scopes})
        end)
    end
  end
end

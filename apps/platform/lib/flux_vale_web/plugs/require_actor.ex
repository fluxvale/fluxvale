defmodule FluxValeWeb.Plugs.RequireActor do
  @moduledoc """
  The API auth gate (#24): halts with a JSON:API 401 error document when
  `FluxValeWeb.Plugs.Authenticate` resolved no user.

  Machine clients get one boring error shape and a strict 401/403 split:
  401 = no or invalid credentials (this plug); 403 = authenticated but
  policy-denied (ash_json_api's standard rendering). Both are JSON:API
  error documents — never plain text, never bespoke payloads.
  """

  import Plug.Conn

  require Logger

  @unauthorized_body Jason.encode!(%{
                       errors: [
                         %{
                           status: "401",
                           title: "Unauthorized",
                           detail: "Missing or invalid credentials"
                         }
                       ]
                     })

  @doc false
  @spec init(keyword) :: keyword
  def init(opts), do: opts

  @doc """
  Halts the connection with a 401 JSON:API error document (plus the
  RFC 6750 `WWW-Authenticate` challenge) when no actor was resolved.
  """
  @spec call(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        Logger.info("API request unauthenticated: #{conn.method} #{conn.request_path}")

        conn
        # charset=nil: ash_json_api's own responses send the bare media type
        # (response.ex), and the JSON:API registration carries no charset —
        # the 401 stays byte-identical to every other API response
        |> put_resp_content_type("application/vnd.api+json", nil)
        |> put_resp_header("www-authenticate", "Bearer")
        |> resp(:unauthorized, @unauthorized_body)
        |> halt()

      _actor ->
        conn
    end
  end
end

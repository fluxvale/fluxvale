defmodule FluxValeWeb.Api.TokenController do
  @moduledoc """
  `POST /api/v1/tokens` — mint a scoped, short-lived personal access
  token (#772; the CLI's `auth token`).

  Plain JSON on the success path: the answer carries a one-time secret,
  like the device flow's grant, and the raw value is never stored or
  logged (the row keeps its SHA-256 hash). Refusals are JSON:API error
  documents like every other `/api/v1` error.

  Authentication is a live PAT. A browser session is refused by the
  boundary plug — writes on `/api/v1` require a token (ADR-0019
  Am. 1). The caller may grant only scopes it already holds, and the
  minted token may not outlive the caller: re-minting can narrow a
  credential, never escalate one.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity

  # The panel's own create form supplies a name; the CLI's default
  # keeps the row identifiable in /settings/developer without one.
  @default_name "fluxvale auth token"
  @max_name_length 100
  # MintPat's own one-year bound, repeated here before the DateTime
  # arithmetic: a huge ttl_seconds must not overflow the calendar.
  @max_ttl_seconds 365 * 24 * 60 * 60

  @doc """
  Mints a token for the authenticated user from the request's
  `scopes`, `ttl_seconds`, and optional `name`.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    # A session caller never reaches here: AuthorizeApiScopes halts
    # every non-GET/HEAD session request on /api/v1 with 401. The arm
    # keeps the controller honest if it is ever mounted outside that
    # pipeline.
    case conn.assigns[:api_pat] do
      nil -> error(conn, 401, "writes on /api/v1 require a personal access token")
      caller -> create_for(conn, caller, params)
    end
  end

  defp create_for(conn, caller, params) do
    with {:ok, scopes} <- scopes(params["scopes"]),
         :ok <- within_caller_scopes(caller, scopes),
         {:ok, ttl_seconds} <- ttl(params["ttl_seconds"]),
         {:ok, name} <- name(params["name"]) do
      mint(conn, name, scopes, ttl_seconds)
    else
      {:error, status, detail} -> error(conn, status, detail)
    end
  end

  defp scopes(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1) do
      case Scopes.validate(scopes) do
        :ok ->
          {:ok, scopes}

        {:error, {:invalid_scope, scope}} ->
          {:error, 400, "unknown scope #{scope}"}

        {:error, {:duplicate_scope, scope}} ->
          {:error, 400, "duplicate scope #{scope}"}
      end
    else
      {:error, 400, "scopes must be an array of scope strings"}
    end
  end

  defp scopes(_other), do: {:error, 400, "scopes must be an array of scope strings"}

  defp within_caller_scopes(caller, scopes) do
    case Enum.find(scopes, &(not Scopes.grants?(caller.scopes, &1))) do
      nil -> :ok
      scope -> {:error, 403, "the caller's token does not grant scope #{scope}"}
    end
  end

  defp ttl(seconds) when is_integer(seconds) and seconds > 0 do
    {:ok, min(seconds, @max_ttl_seconds)}
  end

  defp ttl(_other), do: {:error, 400, "ttl_seconds must be a positive integer"}

  defp name(nil), do: {:ok, @default_name}

  defp name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, 400, "name must not be blank"}

      String.length(trimmed) > @max_name_length ->
        {:error, 400, "name must be at most #{@max_name_length} characters"}

      true ->
        {:ok, trimmed}
    end
  end

  defp name(_other), do: {:error, 400, "name must be a string"}

  defp mint(conn, name, scopes, ttl_seconds) do
    now = DateTime.utc_now()
    requested = DateTime.add(now, ttl_seconds, :second)
    caller = conn.assigns.api_pat
    expires_at = earliest(requested, caller.expires_at)

    case Identity.mint_pat(conn.assigns.current_user, %{
           user_id: caller.user_id,
           name: name,
           scopes: scopes,
           expires_at: expires_at,
           metadata: %{
             "minted_via" => "cli_token",
             "minted_parent_id" => caller.id
           }
         }) do
      {:ok, %{token: raw, pat: pat}} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")
        |> put_status(201)
        |> json(%{
          id: pat.id,
          name: pat.name,
          access_token: raw,
          token_type: "Bearer",
          scope: Enum.join(pat.scopes, " "),
          expires_at: DateTime.to_iso8601(pat.expires_at)
        })

      # Only a system failure can land here: scopes, name, and expiry
      # are validated above. Never echo the changeset — it carries the
      # private token hash.
      {:error, _changeset} ->
        error(conn, 500, "the token could not be minted")
    end
  end

  # A child credential may narrow its parent, never extend it. This
  # is a lifetime check on top of the scope-subset rule.
  defp earliest(requested, caller_expiry) do
    if DateTime.before?(requested, caller_expiry), do: requested, else: caller_expiry
  end

  defp error(conn, status, detail) do
    body =
      Jason.encode!(%{
        errors: [%{status: Integer.to_string(status), title: title(status), detail: detail}]
      })

    conn
    |> put_resp_content_type("application/vnd.api+json", nil)
    |> resp(status, body)
  end

  defp title(400), do: "Bad Request"
  defp title(401), do: "Unauthorized"
  defp title(403), do: "Forbidden"
  defp title(_other), do: "Internal Server Error"
end

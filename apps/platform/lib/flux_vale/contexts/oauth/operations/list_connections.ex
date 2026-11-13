defmodule FluxVale.OAuth.Operations.ListConnections do
  @moduledoc """
  The settings page's Connected apps read (#766): live OAuth token
  families for one user, grouped by `token_family_id`, with the
  registered client's name attached.

  The token read rides the owner policy; the client lookup is system
  metadata (the consent screen already showed it). Revoked rows are
  filtered out — a disconnected family has no live half to list.
  """

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.OAuth.Client

  @doc """
  Returns `{:ok, connections}` — newest first — or an Ash read error.
  """
  @spec call(term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def call(actor, opts \\ []) do
    with {:ok, rows} <-
           PersonalAccessToken.list_oauth_tokens(actor.id, Keyword.put(opts, :actor, actor)) do
      connections =
        rows
        |> Enum.reject(& &1.revoked_at)
        |> Enum.group_by(& &1.token_family_id)
        |> Enum.map(&connection/1)
        |> attach_client_names()
        |> sort_newest_first()

      {:ok, connections}
    end
  end

  defp connection({family_id, rows}) do
    latest = Enum.max_by(rows, & &1.created_at, DateTime)
    created_at = Enum.min_by(rows, & &1.created_at, DateTime).created_at

    stamps =
      rows
      |> Enum.map(& &1.last_used_at)
      |> Enum.reject(&is_nil/1)

    last_used_at =
      case stamps do
        [] -> nil
        present -> Enum.max(present, DateTime)
      end

    %{
      family_id: family_id,
      oauth_client_id: latest.oauth_client_id,
      client_name: "MCP client",
      scopes: latest.scopes,
      resource: latest.resource,
      created_at: created_at,
      last_used_at: last_used_at,
      token_count: length(rows)
    }
  end

  defp attach_client_names(connections) do
    connections
    |> Enum.map(& &1.oauth_client_id)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn client_id, names ->
      case Client.get_by_id(client_id, authorize?: false) do
        {:ok, client} -> Map.put(names, client_id, client.client_name)
        {:error, _missing} -> names
      end
    end)
    |> then(fn names ->
      Enum.map(connections, fn connection ->
        Map.put(
          connection,
          :client_name,
          Map.get(names, connection.oauth_client_id, "MCP client")
        )
      end)
    end)
  end

  defp sort_newest_first(connections) do
    Enum.sort_by(connections, & &1.created_at, {:desc, DateTime})
  end
end

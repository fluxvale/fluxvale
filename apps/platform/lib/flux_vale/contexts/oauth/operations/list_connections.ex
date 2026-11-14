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
      now = DateTime.utc_now()

      connections =
        rows
        |> Enum.group_by(& &1.token_family_id)
        |> Enum.map(fn {family_id, family_rows} -> connection(family_id, family_rows, now) end)
        |> Enum.reject(&is_nil/1)
        |> attach_client_names()
        |> sort_newest_first()

      {:ok, connections}
    end
  end

  defp connection(family_id, rows, now) do
    case Enum.filter(rows, &live?(&1, now)) do
      [] ->
        nil

      live ->
        # Current token attributes come from the live half; created_at
        # and last_used_at span the family's whole history, so a
        # rotation does not reset the connection's age or usage stamp.
        latest = Enum.max_by(live, & &1.created_at, DateTime)
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
          token_count: length(live)
        }
    end
  end

  defp live?(row, now), do: is_nil(row.revoked_at) and DateTime.after?(row.expires_at, now)

  defp attach_client_names(connections) do
    connections
    |> Enum.map(& &1.oauth_client_id)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn client_id, names ->
      case Client.get_by_id(client_id, authorize?: false) do
        {:ok, client} ->
          Map.put(names, client_id, client.client_name)

        # coveralls-ignore-start - the FK cascades token rows with a
        # deleted client; the fallback only guards a mid-read delete.
        {:error, _missing} ->
          names
          # coveralls-ignore-stop
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

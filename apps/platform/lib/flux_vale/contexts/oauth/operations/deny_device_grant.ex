defmodule FluxVale.OAuth.Operations.DenyDeviceGrant do
  @moduledoc """
  The hosted page's Deny (#886 S2): a still-pending grant goes
  terminal-denied — the poll answers `access_denied` forever after.

  The guarded write is the race answer: a grant that approved or
  consumed between the page's read and this write matches zero rows —
  StaleRecord to the caller.
  """

  alias FluxVale.OAuth.DeviceGrant

  @doc """
  Denies `grant` for `actor`. `opts` carries the actor (`actor: user`)
  and optional `now:` (defaults to `DateTime.utc_now()`). A missing
  actor or an expired grant is refused BEFORE any write (mirroring
  `ApproveDeviceGrant`).

  Returns `{:ok, grant}`, `{:error, :actor_required}`,
  `{:error, :expired}`, or `{:error, :stale}` when the row moved.
  """
  @spec call(DeviceGrant.t(), keyword()) ::
          {:ok, DeviceGrant.t()} | {:error, :actor_required | :expired | :stale | term()}
  def call(grant, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      opts[:actor] == nil ->
        {:error, :actor_required}

      DateTime.compare(grant.expires_at, now) == :lt ->
        {:error, :expired}

      true ->
        deny(grant, opts)
    end
  end

  # System write (the RequestWindow posture — the approve twin).
  defp deny(grant, opts) do
    clean_opts = Keyword.delete(opts, :now)
    action_opts = Keyword.put_new(clean_opts, :authorize?, false)

    case DeviceGrant.deny(grant, action_opts) do
      {:ok, denied} ->
        FluxVale.OAuth.record_audit_event(%{
          kind: :device_grant_denied,
          oauth_client_id: denied.client_id,
          actor_id: opts[:actor].id,
          resource: denied.resource,
          metadata: %{"scopes" => denied.scopes}
        })

        {:ok, denied}

      # The guarded write lost the race (the approve twin's matcher).
      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
          {:error, :stale}
        else
          {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end
end

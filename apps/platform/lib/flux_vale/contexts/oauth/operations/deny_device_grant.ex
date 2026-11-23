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
  Denies `grant`. Returns `{:ok, grant}` or `{:error, :stale}` when
  the row moved.
  """
  @spec call(DeviceGrant.t(), keyword()) :: {:ok, DeviceGrant.t()} | {:error, :stale | term()}
  def call(grant, opts \\ []) do
    # System write (the RequestWindow posture — the approve twin).
    opts = Keyword.put_new(opts, :authorize?, false)

    case DeviceGrant.deny(grant, opts) do
      {:ok, denied} ->
        FluxVale.OAuth.record_audit_event(%{
          kind: :device_grant_denied,
          oauth_client_id: denied.client_id,
          actor_id: opts[:actor] && opts[:actor].id,
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

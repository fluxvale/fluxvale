defmodule FluxVale.OAuth.Operations.ApproveDeviceGrant do
  @moduledoc """
  The hosted page's Allow (#886 S2): binds the still-pending grant to
  the approving user (the actor — never a caller-supplied id; the poll
  then mints the pair FOR that user) and records the decision.

  The guarded write is the race answer: a grant that denied or
  consumed between the page's read and this write matches zero rows —
  StaleRecord to the caller.
  """

  alias FluxVale.OAuth.DeviceGrant

  @doc """
  Approves `grant` for `actor`. `opts` carries the actor
  (`actor: user`) — the :approve action binds the row to it (the
  session gate is the hosted page's; the write itself is system-side,
  the IssueAuthorizationCode posture). A missing actor is refused
  BEFORE any write: an actor-less approve would bind no user, burn the
  row at consume, and hand the poll a server_error (#886 hostile
  finding — the operation is the gate, not the doc comment).

  Returns `{:ok, grant}`, `{:error, :actor_required}`, or
  `{:error, :stale}` when the row moved.
  """
  @spec call(DeviceGrant.t(), keyword()) ::
          {:ok, DeviceGrant.t()} | {:error, :actor_required | :stale | term()}
  def call(grant, opts \\ []) do
    if opts[:actor] == nil do
      {:error, :actor_required}
    else
      approve(grant, opts)
    end
  end

  # System write (the RequestWindow posture): the hosted page's
  # session + signed consent token are the actor gate; the row
  # write itself runs without policies, like every other OAuth
  # decision write.
  defp approve(grant, opts) do
    opts = Keyword.put_new(opts, :authorize?, false)

    case DeviceGrant.approve(grant, opts) do
      {:ok, approved} ->
        FluxVale.OAuth.record_audit_event(%{
          kind: :device_grant_approved,
          oauth_client_id: approved.client_id,
          actor_id: approved.user_id,
          resource: approved.resource,
          metadata: %{"scopes" => approved.scopes}
        })

        {:ok, approved}

      # The guarded write lost the race — the row moved between the
      # page's read and this write (the StaleRecord shape arrives
      # wrapped, the Identity poll's matcher).
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

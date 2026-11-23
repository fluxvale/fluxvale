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
  the IssueAuthorizationCode posture). Accepts `now:` (defaults to
  `DateTime.utc_now()`) for deterministic expiry checks. A missing
  actor or an expired grant is refused BEFORE any write.

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
        approve(grant, opts)
    end
  end

  # System write (the RequestWindow posture): the hosted page's
  # session + signed consent token are the actor gate; the row
  # write itself runs without policies, like every other OAuth
  # decision write.
  defp approve(grant, opts) do
    clean_opts = Keyword.delete(opts, :now)
    action_opts = Keyword.put_new(clean_opts, :authorize?, false)

    case DeviceGrant.approve(grant, action_opts) do
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

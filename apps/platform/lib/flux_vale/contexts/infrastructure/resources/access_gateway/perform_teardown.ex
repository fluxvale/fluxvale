defmodule FluxVale.Infrastructure.AccessGateway.PerformTeardown do
  @moduledoc """
  Opt-out teardown (ADR-0039 §5): detach every attached instance, delete
  the gateway's cluster objects, hard-delete the row.

  Detach-first is the contract: each detach returns its instance's
  NetworkPolicy to the private floor and rewrites the serve config, so
  no instance is ever left pointing at a gateway that no longer exists.
  The provider's `teardown_gateway/1` does that and then deletes the
  objects; this module runs it, then the row.

  Failure posture (the instance teardown's): return the error so Oban
  retries; `mark_teardown_error` surfaces exhaustion as
  `:needs_attention` with the row and its objects intact — a retry can
  finish what the first attempt started.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, gateway ->
      teardown(gateway)
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  defp teardown(gateway) do
    provider = AccessProvider.impl_for(gateway)

    case provider.teardown_gateway(gateway) do
      :ok -> destroy_row(gateway)
      {:error, reason} = error -> fail(gateway, reason, error)
    end
  end

  defp destroy_row(gateway) do
    changeset =
      Ash.Changeset.for_destroy(gateway, :destroy_after_teardown, %{}, authorize?: false)

    # Ash's destroy returns :ok when the action carries no publish
    # (this system action publishes nothing) and {:ok, notifications}
    # when it does — accept both rather than couple to the notifier's
    # presence.
    result = Ash.destroy(changeset)

    case result do
      :ok ->
        {:ok, gateway}

      # Defensive: Ash returns :ok today (this action publishes
      # nothing); the tuple arm is the notifier-present shape.
      # coveralls-ignore-next-line
      {:ok, _notifications} ->
        {:ok, gateway}

      # coveralls-ignore-start - defensive: DB failure on the delete
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  # The row survives for Oban's retry — that is the whole contract here.
  # The message cannot persist from inside this transaction: a failed
  # action rolls its writes back, so the update below would vanish with
  # it. The trigger's exhaustion handler (`mark_teardown_error`) is the
  # write that lands the visible copy, one retry later; until then the
  # panel keeps showing the state the delete action set (`:destroying`).
  defp fail(gateway, reason, error) do
    Logger.error("Access gateway #{gateway.id} teardown failed: #{inspect(reason)}")
    error
  end
end

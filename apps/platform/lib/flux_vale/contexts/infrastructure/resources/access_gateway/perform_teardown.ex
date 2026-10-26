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

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, gateway ->
      case AccessProvider.impl_for(gateway).teardown_gateway(gateway) do
        :ok ->
          case gateway
               |> Ash.Changeset.for_destroy(:destroy_after_teardown, %{}, authorize?: false)
               |> Ash.destroy(return_notifications?: true) do
            {:ok, _destroyed, _notifications} ->
              {:ok, gateway}

            # coveralls-ignore-start - defensive: DB failure on the delete
            {:error, reason} ->
              {:error, reason}
              # coveralls-ignore-stop
          end

        {:error, reason} = error ->
          Logger.error("Access gateway #{gateway.id} teardown failed: #{inspect(reason)}")

          # The row stays :destroying so the retry finds it and the panel
          # keeps showing "Removing access" until it lands.
          _ = mark_destroying(gateway)
          error
      end
    end)
  end

  @impl Ash.Resource.Change
  def atomic?, do: false

  # Best-effort message update: a failure here must not mask the
  # teardown error the caller will retry on.
  defp mark_destroying(%AccessGateway{} = gateway) do
    gateway
    |> Ash.Changeset.for_update(
      :update_state,
      %{state: :destroying, status_message: "Removal is retrying"},
      authorize?: false
    )
    |> Ash.update()
  end
end

defmodule FluxVale.Identity.Operations.RemoveEmail do
  @moduledoc """
  The actor removes one of their addresses (#285 T3): a thin actor-gated
  wrapper over `UserEmail.remove` — the guards (never the primary, never
  the last verified) live on the resource. The op locates the row among
  the actor's own and runs the action under their authorization.
  """

  alias FluxVale.Identity.UserEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  @doc """
  `:ok` on success; `{:error, :not_found}` when the row is not among the
  actor's; resource refusals (primary, last verified) surface as
  `{:error, reason}`.
  """
  @spec call(term(), Ash.UUID.t()) :: :ok | {:error, term()}
  def call(actor, email_row_id) do
    with {:ok, row} <- mine(actor, email_row_id) do
      UserEmail.remove(row, actor: actor)
    end
  end

  defp mine(actor, email_row_id) do
    outcome =
      UserEmail
      |> Ash.Query.for_read(:mine, %{}, actor: actor)
      |> Ash.Query.filter(id == ^email_row_id)
      |> Ash.read()

    case outcome do
      {:ok, [row]} ->
        {:ok, row}

      {:ok, []} ->
        {:error, :not_found}

      # coveralls-ignore-start - DB read failure: not simulatable under
      # the sandbox
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end
end

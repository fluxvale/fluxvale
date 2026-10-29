defmodule FluxVale.Identity.Operations.SetPrimaryEmail do
  @moduledoc """
  The actor promotes one of their verified addresses to primary
  (#285 T3): a thin actor-gated wrapper over `UserEmail.set_primary` —
  the guards (verified-only, at-most-one primary, sibling demotion) live
  on the resource. The op locates the row among the actor's own and runs
  the action under their authorization, so the future UI gets uniform
  `:not_found` for rows that are not theirs.
  """

  alias FluxVale.Identity.UserEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  @doc """
  `{:ok, promoted_row}` on success; `{:error, :not_found}` when the row
  is not among the actor's; resource refusals (pending row) surface as
  `{:error, reason}`.
  """
  @spec call(term(), Ash.UUID.t()) :: {:ok, UserEmail.t()} | {:error, term()}
  def call(actor, email_row_id) do
    with {:ok, row} <- mine(actor, email_row_id) do
      UserEmail.set_primary(row, actor: actor)
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

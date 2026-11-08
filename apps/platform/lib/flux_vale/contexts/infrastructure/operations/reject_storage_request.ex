defmodule FluxVale.Infrastructure.Operations.RejectStorageRequest do
  @moduledoc """
  The operator's rejection (#250, ADR-0046 §3) — the authorized read +
  `:reject` as the admin, with the member-visible feedback required.

  Works on a `requested` row and on an `approved` one that can never
  apply (the escape hatch); the rejection is terminal either way.
  """

  alias FluxVale.Infrastructure.StorageRequest

  @doc """
  Rejects `request_id` as `actor` with `feedback`.
  """
  @spec call(FluxVale.Identity.User.t(), Ash.UUID.t(), String.t()) ::
          {:ok, StorageRequest.t()} | {:error, term()}
  def call(actor, request_id, feedback) do
    with {:ok, request} <- StorageRequest.get_by_id(request_id, actor: actor) do
      StorageRequest.reject(request, %{rejection_reason: feedback}, actor: actor)
    end
  end
end

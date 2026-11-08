defmodule FluxVale.Infrastructure.Operations.RetryStorageRequest do
  @moduledoc """
  The operator's apply retry (#250, ADR-0046 §3): re-runs the mechanical
  step on an approved request without re-deciding it.

  The authorized read + `:retry_apply` as the admin, then the shared
  `ApplyStorageRequest` (idempotent, so an apply that already reached
  the volume converges instead of failing on the refused no-op).
  """

  alias FluxVale.Infrastructure.Operations.ApplyStorageRequest
  alias FluxVale.Infrastructure.StorageRequest

  @doc """
  Retries `request_id`'s apply as `actor`. Returns the request's
  post-apply truth (applied, or approved with the fresh `apply_error`).
  """
  @spec call(FluxVale.Identity.User.t(), Ash.UUID.t()) ::
          {:ok, StorageRequest.t()} | {:error, term()}
  def call(actor, request_id) do
    with {:ok, request} <- StorageRequest.get_by_id(request_id, actor: actor),
         {:ok, retried} <- StorageRequest.retry_apply(request, %{}, actor: actor) do
      ApplyStorageRequest.call(retried)
    end
  end
end

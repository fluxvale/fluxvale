defmodule FluxVale.Infrastructure.Operations.ApproveStorageRequest do
  @moduledoc """
  The operator's one-click approval (#250, ADR-0046 §3): the authorized
  read + `:approve` decision as the admin, then the shared
  `ApplyStorageRequest`.

  The decision commits first and is durable; the apply's failure leaves
  the returned row `approved` with `apply_error` for the queue's Retry
  button — never a rolled-back approval.
  """

  alias FluxVale.Infrastructure.Operations.ApplyStorageRequest
  alias FluxVale.Infrastructure.StorageRequest

  @doc """
  Approves `request_id` as `actor` and applies it. Returns the request's
  post-apply truth: `:applied` on success, `approved` with
  `apply_error` when the volume patch failed.
  """
  @spec call(FluxVale.Identity.User.t(), Ash.UUID.t()) ::
          {:ok, StorageRequest.t()} | {:error, term()}
  def call(actor, request_id) do
    with {:ok, request} <- StorageRequest.get_by_id(request_id, actor: actor),
         {:ok, approved} <- StorageRequest.approve(request, %{}, actor: actor) do
      ApplyStorageRequest.call(approved)
    end
  end
end

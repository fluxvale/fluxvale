defmodule FluxVale.Infrastructure.Operations.ApplyStorageRequest do
  @moduledoc """
  The approved request's mechanical apply (#250, ADR-0046 §9) — the
  shared second half of approve and retry, deliberately separate from
  the durable decision.

  **Idempotent**: the instance is re-read system-side (`authorize?:
  false` — the request's own approve policy already gated the
  operator) and, when its allocation is already at or above the
  requested total, the request is marked applied without touching the
  cluster. That is the crash recovery: an apply that reached the volume
  but lost its mark converges on the retry instead of failing on
  `:grow_storage`'s refused no-op.

  Otherwise the online storage-only `Instance :grow_storage` runs (the
  S3 path: settle-before-flip, re-price, PVC + quota). On success the
  request is marked applied; on any error it stays approved with an
  honest `apply_error`, ready for the operator's retry — the decision
  is never rolled back. A missing or mid-teardown instance records the
  failure the same way; the member is never left waiting on an approval
  the box cannot honor.
  """

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.StorageRequest

  # The apply_error column is internal; this bound keeps a pathological
  # error term from becoming a multi-megabyte row.
  @error_cap 1_000

  @doc """
  Applies `request` (approved) and marks the outcome. Returns
  `{:ok, request}` where the row is `:applied` on success or stays
  `:approved` with `apply_error` on failure — the caller renders the
  row's status, the truth of the operation.
  """
  @spec call(StorageRequest.t()) :: {:ok, StorageRequest.t()} | {:error, term()}
  def call(%StorageRequest{} = request) do
    case Instance.get_by_id(request.instance_id, authorize?: false) do
      {:ok, instance} ->
        converge(instance, request)

      {:error, reason} ->
        fail(request, reason)
    end
  end

  defp converge(instance, request) do
    if instance.storage_gb >= request.requested_gb do
      mark_applied(request)
    else
      grow(instance, request)
    end
  end

  defp grow(instance, request) do
    params = %{storage_gb: request.requested_gb}

    case Instance.grow_storage(instance, params, authorize?: false) do
      {:ok, _grown} -> mark_applied(request)
      {:error, reason} -> fail(request, reason)
    end
  end

  defp mark_applied(request) do
    StorageRequest.mark_applied(request, %{}, authorize?: false)
  end

  defp fail(request, reason) do
    StorageRequest.mark_apply_failed(
      request,
      %{error: failure_message(reason)},
      authorize?: false
    )
  end

  # The first useful sentence of an Ash error, not its multi-line
  # inspect — the operator's queue row reads it.
  defp failure_message(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
      "the instance no longer exists"
    else
      errors
      |> Enum.map_join("; ", &Exception.message/1)
      |> truncate()
    end
  end

  # coveralls-ignore-start - defensive: every caller's tuple is an Ash
  # error class today (the vanished-instance test pins the wrapped
  # NotFound shape); a future direct exception still formats honestly
  # through this arm rather than crashing the apply.
  defp failure_message(%{__exception__: true} = error), do: truncate(Exception.message(error))
  # coveralls-ignore-stop

  # coveralls-ignore-start - defensive: every caller's tuple is an Ash
  # exception; a bare term is a future caller's shape, kept honest
  # rather than crashing the apply.
  defp failure_message(other), do: truncate(inspect(other))
  # coveralls-ignore-stop

  defp truncate(message) when is_binary(message) do
    if String.length(message) > @error_cap do
      String.slice(message, 0, @error_cap)
    else
      message
    end
  end
end

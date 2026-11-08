defmodule FluxVale.Infrastructure.Types.StorageRequestStatus do
  @moduledoc """
  A storage request's lifecycle (#250, ADR-0046):

  - `:requested` — the member asked; the operator queue owns it.
  - `:approved` — the operator decided. The apply is the retryable
    mechanical step that follows; `apply_error` says why the last
    attempt failed.
  - `:rejected` — terminal, with the member-visible feedback
    (`rejection_reason`). Also the escape hatch for an approved request
    the infrastructure can never apply.
  - `:applied` — terminal, the volume reached the requested total.

  Text-stored like the instance statuses — adding a value is code-only.
  """

  use Ash.Type.Enum, values: [:requested, :approved, :rejected, :applied]
end

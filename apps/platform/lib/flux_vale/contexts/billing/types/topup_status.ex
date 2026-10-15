defmodule FluxVale.Billing.Types.TopupStatus do
  @moduledoc """
  Top-up lifecycle (M6, ADR-0029):

  - `:pending` — created, awaiting gateway outcome (checkout open or
    payment in flight).
  - `:completed` — a verified payment landed; the wallet credit posted
    (idempotently, by payment id).
  - `:failed` — checkout creation failed or the payment request failed;
    no credit ever posts from this row.
  """

  use Ash.Type.Enum, values: [:pending, :completed, :failed]
end

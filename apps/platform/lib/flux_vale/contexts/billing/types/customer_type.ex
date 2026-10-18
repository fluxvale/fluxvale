defmodule FluxVale.Billing.Types.CustomerType do
  @moduledoc """
  Who is buying, captured at checkout (ADR-0029 Am. 3 gate 2): the
  buyer type decides B2B reverse charge — a business with a VAT number
  self-accounts (`FluxVale.Billing.Tax.reverse_charge?/2`), a consumer
  pays the billing country's rate.

  - `:consumer` — the default; every buyer is one until they say
    otherwise.
  - `:business` — with a format-valid VAT number, reverse charge.
  """

  use Ash.Type.Enum, values: [:consumer, :business]
end

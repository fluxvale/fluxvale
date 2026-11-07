defmodule FluxVale.Billing.Proration do
  @moduledoc """
  Flat-rate proration math — the one money-path boundary (precedent:
  `FluxVale.Billing.Month` owns the one month constant).

  It exposes two primitives, because the two settles keep different
  rounding contracts and both are deliberate:

  - `prorate_decimal/2` returns the exact, unfloored Decimal. The
    instance settle adds the running and stopped shares, then floors
    the sum once.
  - `prorate_micro_cents/2` floors each rate to integer micro-cents. The
    gateway settle floors per rate.

  `usecs_between/2` and `month_useconds/0` are shared so the two
  settles cannot disagree about an interval or a month.
  """

  alias FluxVale.Billing.Month

  @micros_per_cent Decimal.new(10_000)

  @doc "The average Gregorian month in microseconds (the proration divisor)."
  @spec month_useconds() :: pos_integer()
  def month_useconds, do: Month.useconds()

  @doc """
  The non-negative duration between two datetimes, in microseconds.
  A reversed interval reads as zero.
  """
  @spec usecs_between(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def usecs_between(from, to) do
    max(DateTime.diff(to, from, :microsecond), 0)
  end

  @doc """
  `cents` prorated over `usecs`, exact and unfloored, in micro-cents.

  The caller owns the final rounding (the instance settle floors the
  summed shares).
  """
  @spec prorate_decimal(non_neg_integer(), non_neg_integer()) :: Decimal.t()
  def prorate_decimal(cents, usecs) do
    cents
    |> Decimal.new()
    |> Decimal.mult(@micros_per_cent)
    |> Decimal.mult(usecs)
    |> Decimal.div(month_useconds_decimal())
  end

  @doc """
  `cents` prorated over `usecs`, floored to integer micro-cents.

  The gateway settle floors each rate through this. The floored
  sub-micro-cent residue is discarded, never pooled.
  """
  @spec prorate_micro_cents(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def prorate_micro_cents(cents, usecs) do
    proration = prorate_decimal(cents, usecs)

    proration
    |> Decimal.round(0, :floor)
    |> Decimal.to_integer()
  end

  # Bound through a function, not a module attribute, so Month carries
  # no compile-order dependency on this module (the settles' comment).
  defp month_useconds_decimal, do: Decimal.new(Month.useconds())
end

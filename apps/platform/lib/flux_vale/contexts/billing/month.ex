defmodule FluxVale.Billing.Month do
  @moduledoc """
  The average Gregorian month (2_629_746 s) — the ONE calendar-neutral
  constant every flat-rate prorate and the runway divide by (#121's
  instance settle, ADR-0039 §5's gateways, ADR-0040 §11's domains).
  One definition, on purpose: a fork here would make the settles and
  the runway projection disagree about what a month of money is.
  """

  @seconds 2_629_746
  @useconds @seconds * 1_000_000

  @doc "The average Gregorian month in seconds (the runway's divisor)."
  @spec seconds() :: pos_integer()
  def seconds, do: @seconds

  @doc "The average Gregorian month in microseconds (the settles' divisor)."
  @spec useconds() :: pos_integer()
  def useconds, do: @useconds
end

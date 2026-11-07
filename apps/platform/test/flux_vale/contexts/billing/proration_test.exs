defmodule FluxVale.Billing.ProrationTest do
  use ExUnit.Case, async: true

  alias FluxVale.Billing.Proration

  # The average Gregorian month: 2_629_746 seconds.
  @month 2_629_746_000_000
  @half_month div(@month, 2)

  describe "month_useconds/0" do
    test "is the one month constant, in microseconds" do
      assert Proration.month_useconds() == @month
    end
  end

  describe "usecs_between/2" do
    test "measures a real interval" do
      from = ~U[2026-01-01 00:00:00Z]
      to = ~U[2026-01-01 00:00:00.000002Z]

      assert Proration.usecs_between(from, to) == 2
    end

    test "a zero interval is zero" do
      now = ~U[2026-01-01 00:00:00Z]

      assert Proration.usecs_between(now, now) == 0
    end

    test "a reversed interval floors at zero" do
      later = ~U[2026-01-01 00:00:01Z]
      earlier = ~U[2026-01-01 00:00:00Z]

      assert Proration.usecs_between(later, earlier) == 0
    end
  end

  describe "prorate_decimal/2" do
    test "a full month at $1.00 is one dollar in micro-cents" do
      # 100 cents = 1_000_000 micro-cents
      result = Proration.prorate_decimal(100, @month)

      assert Decimal.equal?(result, Decimal.new(1_000_000))
    end

    test "half a month at $1.00 is fifty cents" do
      result = Proration.prorate_decimal(100, @half_month)

      assert Decimal.equal?(result, Decimal.new(500_000))
    end

    test "keeps the unfloored residue (the instance settle floors the sum)" do
      residue = Proration.prorate_decimal(1, 1)

      assert Decimal.gt?(residue, Decimal.new(0))
      assert Decimal.lt?(residue, Decimal.new(1))
    end

    test "a zero interval is zero" do
      result = Proration.prorate_decimal(100, 0)

      assert Decimal.equal?(result, Decimal.new(0))
    end
  end

  describe "prorate_micro_cents/2" do
    test "a full month at $1.00 is one dollar in micro-cents" do
      assert Proration.prorate_micro_cents(100, @month) == 1_000_000
    end

    test "half a month at $1.00 is fifty cents" do
      assert Proration.prorate_micro_cents(100, @half_month) == 500_000
    end

    test "floors a sub-micro-cent residue to zero" do
      assert Proration.prorate_micro_cents(1, 1) == 0
    end

    test "a zero interval is zero" do
      assert Proration.prorate_micro_cents(100, 0) == 0
    end

    test "the two contracts disagree on the same shares (why both exist)" do
      # Two shares of ~0.60006 micro-cents each: the instance settle
      # adds the exact Decimals and floors once (1), the gateway settle
      # floors each share (0).
      each = 157_800_000
      share = Proration.prorate_decimal(1, each)

      summed =
        share
        |> Decimal.add(share)
        |> Decimal.round(0, :floor)
        |> Decimal.to_integer()

      floored_each =
        Proration.prorate_micro_cents(1, each) + Proration.prorate_micro_cents(1, each)

      assert summed == 1
      assert floored_each == 0
    end
  end
end

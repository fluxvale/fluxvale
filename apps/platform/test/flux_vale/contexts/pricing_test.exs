defmodule FluxVale.PricingTest do
  @moduledoc """
  The Pricing domain module's display helpers: the reminder lane's
  money rule (#829) — whole dollars read the bare dollar figure,
  non-round cents render exact.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Pricing

  describe "format_usd_whole_or_exact/1 (#829)" do
    test "whole dollars read the bare dollar figure (the launch defaults' shape)" do
      assert Pricing.format_usd_whole_or_exact(2_500) == "$25"
      assert Pricing.format_usd_whole_or_exact(500) == "$5"
      assert Pricing.format_usd_whole_or_exact(0) == "$0"
    end

    # A div(…, 100) threshold is honest only when the cents are: 550¢
    # fires at $5.49 and must not read "$5".
    test "non-round cents render exact, never a floored dollar" do
      assert Pricing.format_usd_whole_or_exact(549) == "$5.49"
      assert Pricing.format_usd_whole_or_exact(2_550) == "$25.50"
    end
  end
end

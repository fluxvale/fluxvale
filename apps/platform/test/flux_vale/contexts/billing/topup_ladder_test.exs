defmodule FluxVale.Billing.TopupLadderTest do
  use ExUnit.Case, async: true

  alias FluxVale.Billing

  # The top-up ladder (#888, ADR-0046 Am. 2): the rungs and the floor are
  # pinned config, and one predicate decides a valid amount. This table
  # is the agreement check — StartTopup's tests assert the same
  # boundaries through the operation, the wizard's through its form.

  @valid [500, 1000, 1500, 2000, 2001, 2550, 100_000]
  @invalid [-1, 0, 50, 499, 501, 700, 999, 1001, 1499, 1501, 1999]

  test "the ladder and its floor are pinned config" do
    assert Billing.min_topup_cents() == 500
    assert Billing.topup_ladder_cents() == [500, 1000, 1500, 2000]
    assert Billing.topup_ladder_dollars() == [5, 10, 15, 20]
    # The bottom rung IS the floor the paid-feature prompts name.
    assert hd(Billing.topup_ladder_cents()) == Billing.min_topup_cents()
  end

  test "a rung, or anything above the top rung, is valid" do
    for cents <- @valid do
      assert Billing.topup_amount_valid?(cents), "#{cents} should be valid"
    end
  end

  test "anything between the floor and the top rung that is not a rung is invalid" do
    for cents <- @invalid do
      refute Billing.topup_amount_valid?(cents), "#{cents} should be invalid"
    end
  end

  test "a non-integer amount is invalid" do
    refute Billing.topup_amount_valid?("500")
    refute Billing.topup_amount_valid?(5.0)
    refute Billing.topup_amount_valid?(nil)
  end
end

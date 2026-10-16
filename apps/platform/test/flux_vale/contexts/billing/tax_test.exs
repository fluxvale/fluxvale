defmodule FluxVale.Billing.TaxTest do
  @moduledoc """
  The checkout tax layer's shared math and evidence rules (#138): the
  half-up tax formula, the B2B reverse-charge format check, the OSS
  location match, and the percent label.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Billing.Tax

  describe "tax_cents/2 — VAT on the net, half-up to the cent" do
    test "whole cents compute exactly" do
      assert Tax.tax_cents(500, 1900) == 95
      assert Tax.tax_cents(100, 2000) == 20
      assert Tax.tax_cents(1000, 0) == 0
      assert Tax.tax_cents(100, 10_000) == 100
    end

    test "exact halves round up" do
      # 0.5¢ → 1
      assert Tax.tax_cents(1, 5000) == 1
      # 25.5% of $1.00 = 25.5¢ → 26
      assert Tax.tax_cents(100, 2550) == 26
    end

    test "sub-cent fractions round half-up, not down" do
      # 0.57 → 1
      assert Tax.tax_cents(3, 1900) == 1
      # 0.19 → 0
      assert Tax.tax_cents(1, 1900) == 0
      # 2.55 → 3
      assert Tax.tax_cents(15, 1700) == 3
    end
  end

  describe "reverse_charge?/2 — the B2B proof (format check; VIES is a launch gate)" do
    test "a business with a valid VAT number reverse-charges" do
      assert Tax.reverse_charge?(:business, "DE123456789")
      assert Tax.reverse_charge?(:business, "IE1234567AB")
      assert Tax.reverse_charge?(:business, "GB123456789")
    end

    test "consumers never reverse-charge, whatever they typed" do
      refute Tax.reverse_charge?(:consumer, "DE123456789")
      refute Tax.reverse_charge?(:consumer, nil)
    end

    test "a business without a format-valid number pays the country rate" do
      refute Tax.reverse_charge?(:business, nil)
      refute Tax.reverse_charge?(:business, "")
      # lowercase — the input is uppercased upstream; malformed here
      refute Tax.reverse_charge?(:business, "de123456789")
      # one-letter country prefix
      refute Tax.reverse_charge?(:business, "D12345678")
      # too short after the prefix (needs 2–12)
      refute Tax.reverse_charge?(:business, "DEA")
      # separators/spaces are not part of the shape
      refute Tax.reverse_charge?(:business, "DE 123 456")
      # too long after the prefix (12 is the cap)
      refute Tax.reverse_charge?(:business, "DE123456789ABCD")
    end
  end

  describe "location_verified?/2 — exact billing vs IP match" do
    test "an exact match is verified" do
      assert Tax.location_verified?("DE", "DE")
    end

    test "a mismatch is tolerated and recorded, never verified" do
      refute Tax.location_verified?("DE", "FR")
    end

    test "a missing side records nothing" do
      refute Tax.location_verified?("DE", nil)
      refute Tax.location_verified?(nil, "DE")
      refute Tax.location_verified?(nil, nil)
    end
  end

  describe "percent_label/1" do
    test "whole percents render bare" do
      assert Tax.percent_label(0) == "0"
      assert Tax.percent_label(1900) == "19"
      assert Tax.percent_label(2000) == "20"
      assert Tax.percent_label(10_000) == "100"
    end

    test "fractional percents keep the tenth" do
      assert Tax.percent_label(2550) == "25.5"
      assert Tax.percent_label(50) == "0.5"
    end
  end
end

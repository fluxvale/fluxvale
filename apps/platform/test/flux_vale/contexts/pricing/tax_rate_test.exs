defmodule FluxVale.Pricing.TaxRateTest do
  @moduledoc """
  TaxRate resource contract (#138): the dated jurisdiction rows the
  checkout resolves against — constraints, the seed's lookup-key
  identity, and the Size-mirroring policies.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Pricing.TaxRate

  @effective_from ~U[2024-01-01 00:00:00.000000Z]

  defp admin do
    case User.get_by_email("admin@fluxvale.com", authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
    end
  end

  defp regular_user do
    User.create!("regular-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp rate_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        country: "DE",
        rate_bp: 1900,
        effective_from: @effective_from
      },
      Map.new(overrides)
    )
  end

  describe "create/2" do
    test "creates a country-wide row with the accepted fields" do
      assert {:ok, rate} = TaxRate.create(rate_attrs(), authorize?: false)
      assert rate.country == "DE"
      assert rate.state == nil
      assert rate.rate_bp == 1900
      assert DateTime.compare(rate.effective_from, @effective_from) == :eq
    end

    test "creates a state-specific row (US nexus shape)" do
      attrs = rate_attrs(%{country: "US", state: "CA", rate_bp: 800})

      assert {:ok, rate} = TaxRate.create(attrs, authorize?: false)
      assert rate.state == "CA"
    end

    test "rejects non-2-letter countries and states" do
      bad_country = rate_attrs(%{country: "Deutschland"})

      assert {:error, %Ash.Error.Invalid{}} = TaxRate.create(bad_country, authorize?: false)

      bad_state = rate_attrs(%{state: "Calif"})

      assert {:error, %Ash.Error.Invalid{}} = TaxRate.create(bad_state, authorize?: false)
    end

    test "rate_bp is capped at 10000 basis points, never negative" do
      over = rate_attrs(%{rate_bp: 10_001})

      assert {:error, %Ash.Error.Invalid{}} = TaxRate.create(over, authorize?: false)

      negative = rate_attrs(%{rate_bp: -1})

      assert {:error, %Ash.Error.Invalid{}} = TaxRate.create(negative, authorize?: false)
    end

    test "effective_from is required" do
      undated = rate_attrs(%{effective_from: nil})

      assert {:error, %Ash.Error.Invalid{}} = TaxRate.create(undated, authorize?: false)
    end

    test "state-dated dupes are rejected by the unique index" do
      first = rate_attrs(%{country: "US", state: "CA"})
      TaxRate.create!(first, authorize?: false)

      dupe = rate_attrs(%{country: "US", state: "CA"})

      assert {:error, %Ash.Error.Invalid{}} = TaxRate.create(dupe, authorize?: false)
    end

    # The (country, state, effective_from) identity cannot compare
    # NULL state; the partial unique index on
    # (country, effective_from) WHERE state IS NULL closes the gap —
    # two country-wide rows must never share an effective_from (the
    # resolver's latest-row pick would otherwise be a coin flip).
    test "country-wide rows cannot share an effective_from (partial unique index)" do
      TaxRate.create!(rate_attrs(), authorize?: false)

      dupe = rate_attrs(%{rate_bp: 2000})

      assert {:error, %Ash.Error.Invalid{}} = TaxRate.create(dupe, authorize?: false)
    end

    test "the same country at a different date is a new row (no effective_to)" do
      TaxRate.create!(rate_attrs(), authorize?: false)

      later =
        rate_attrs(%{rate_bp: 2000, effective_from: ~U[2026-01-01 00:00:00.000000Z]})

      assert {:ok, _new_row} = TaxRate.create(later, authorize?: false)
    end
  end

  describe "update/2" do
    test "reprices but keeps the lookup key" do
      rate = TaxRate.create!(rate_attrs(), authorize?: false)

      assert {:ok, updated} = TaxRate.update(rate, %{rate_bp: 2000}, authorize?: false)
      assert updated.rate_bp == 2000

      assert {:error, %Ash.Error.Invalid{}} =
               TaxRate.update(rate, %{country: "FR"}, authorize?: false)
    end
  end

  describe "policy (ADR-0027: mutations ride ActorIsPlatformAdmin)" do
    setup do
      %{admin: admin(), regular: regular_user()}
    end

    test "any signed-in actor reads; anonymous is denied", %{regular: regular} do
      TaxRate.create!(rate_attrs(), authorize?: false)

      assert {:ok, [_row]} = Ash.read(TaxRate, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(TaxRate, authorize?: true)
    end

    test "non-admins cannot mutate; admins create and update — the AshAdmin paths",
         %{admin: admin, regular: regular} do
      blocked = rate_attrs(%{country: "FR"})

      assert {:error, %Ash.Error.Forbidden{}} =
               TaxRate.create(blocked, actor: regular, authorize?: true)

      rate = TaxRate.create!(rate_attrs(), authorize?: false)

      assert {:ok, updated} = Ash.update(rate, %{rate_bp: 2000}, actor: admin, authorize?: true)
      assert updated.rate_bp == 2000

      reprice = %{rate_bp: 1}

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(rate, reprice, actor: regular, authorize?: true)
    end
  end
end

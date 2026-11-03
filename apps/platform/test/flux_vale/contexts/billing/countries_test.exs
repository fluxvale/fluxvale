defmodule FluxVale.Billing.CountriesTest do
  @moduledoc """
  Unit tests for the shipped country list (#364) — no database. These
  pin the dataset's shape: the complete ISO 3166-1 alpha-2 set (249),
  unique codes, the accent-folded name sort, and the jurisdictions the
  owner's checkout traffic names.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Billing.Countries

  # Mirrors scripts/generate_countries.exs's sort key: case-folded,
  # accent-folded (NFD + strip combining marks) English name.
  # Codepoints, not graphemes — a decomposed å is one grapheme cluster.
  defp fold(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.codepoints()
    |> Enum.reject(fn
      <<codepoint::utf8>> when codepoint in 0x0300..0x036F -> true
      _base_character -> false
    end)
    |> Enum.join()
  end

  describe "all/0 (shipped data)" do
    test "carries the complete ISO 3166-1 alpha-2 set — 249 unique codes" do
      countries = Countries.all()

      assert length(countries) == 249

      codes = Enum.map(countries, & &1.code)
      assert Enum.uniq(codes) == codes
      assert Enum.all?(codes, &Regex.match?(~r/^[A-Z]{2}$/, &1))

      # Every entry is a two-key map with a non-empty name.
      assert Enum.all?(countries, fn country ->
               keys = Map.keys(country)
               country.name != "" and Enum.sort(keys) == [:code, :name]
             end)
    end

    test "is sorted by accent-folded English name" do
      countries = Countries.all()

      assert countries ==
               Enum.sort_by(countries, &fold(&1.name))
    end

    test "carries the owner's checkout jurisdictions (PH among them)" do
      by_code = Map.new(Countries.all(), &{&1.code, &1.name})

      assert by_code["PH"] == "Philippines"
      assert by_code["DE"] == "Germany"
      assert by_code["US"] == "United States"
      assert by_code["GB"] == "United Kingdom"
    end

    test "accent-folded names sort as typed, not by codepoint" do
      names = Enum.map(Countries.all(), & &1.name)

      # Åland sits with the A-names (after Afghanistan), Côte
      # d'Ivoire as cote — not stranded at the non-ASCII end.
      aland_index = Enum.find_index(names, &(&1 == "Åland Islands"))
      assert Enum.at(names, aland_index - 1) == "Afghanistan"
      assert Enum.at(names, aland_index + 1) == "Albania"

      cote_index = Enum.find_index(names, &(&1 == "Côte d'Ivoire"))
      assert Enum.at(names, cote_index - 1) == "Costa Rica"
      assert Enum.at(names, cote_index + 1) == "Croatia"
    end
  end

  describe "valid?/1" do
    test "accepts listed uppercase codes" do
      assert Countries.valid?("PH")
      assert Countries.valid?("DE")
      assert Countries.valid?("US")
    end

    test "rejects unlisted, lowercase, and malformed codes" do
      refute Countries.valid?("ZZ")
      refute Countries.valid?("ph")
      refute Countries.valid?("PHI")
      refute Countries.valid?("")
      refute Countries.valid?(nil)
      refute Countries.valid?(:ph)
      refute Countries.valid?(42)
    end
  end

  describe "name/1" do
    test "maps a listed code to its English short name" do
      assert Countries.name("PH") == "Philippines"
      assert Countries.name("DE") == "Germany"
    end

    test "unknown codes answer nil" do
      assert Countries.name("ZZ") == nil
      assert Countries.name("ph") == nil
    end
  end
end

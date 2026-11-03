defmodule FluxVale.Billing.Countries do
  @moduledoc """
  The ISO 3166-1 country list backing the top-up wizard's searchable
  country control (#364), read from `priv/data/countries.yaml`.

  This is the DROPDOWN's dataset — code + English short name for every
  officially assigned alpha-2 code (249 entries). It is not the tax
  rate table and never derives from it: rates live in
  `priv/repo/seeds/tax_rates.yaml` and stay the sole rate source. A
  code being listed here says nothing about VAT — unlisted-in-the-rate-
  table countries resolve at 0% through `FluxVale.Pricing`.

  The file is read once and memoized in `:persistent_term` at first
  call (it ships with the release via `:code.priv_dir`, like the rate
  seed data); the list is static for a node's lifetime, so no cache
  invalidation exists. Two racing first calls can both load — the put
  is idempotent and the parse is pure.
  """

  @typedoc "One ISO 3166-1 entry: the alpha-2 code and English short name."
  @type entry :: %{code: String.t(), name: String.t()}

  @pt_all {__MODULE__, :all}
  @pt_by_code {__MODULE__, :by_code}

  @doc """
  Every country, in the shipped file's order — accent-folded English
  name sort (Åland Islands sits between the Al- names, not after Z).
  """
  @spec all :: [entry()]
  def all do
    ensure_loaded()
    :persistent_term.get(@pt_all)
  end

  @doc """
  Whether `code` is a listed ISO 3166-1 alpha-2 code — the details
  step's country validation (case-sensitive: the form normalizes to
  uppercase before checking).
  """
  @spec valid?(term()) :: boolean()
  def valid?(code) when is_binary(code), do: Map.has_key?(by_code(), code)
  def valid?(_not_a_code), do: false

  @doc """
  The English short name for a listed code, nil for anything else.
  """
  @spec name(String.t()) :: String.t() | nil
  def name(code) do
    Map.get(by_code(), code)
  end

  defp by_code do
    ensure_loaded()
    :persistent_term.get(@pt_by_code)
  end

  # Parses on first use, memoizes both shapes. Racing first calls can
  # each parse — the puts are idempotent and the parse is pure.
  defp ensure_loaded do
    if :persistent_term.get(@pt_all, nil) == nil do
      countries =
        default_path()
        |> File.read!()
        |> YamlElixir.read_from_string!()
        |> Enum.map(&normalize_entry/1)

      :persistent_term.put(@pt_all, countries)
      :persistent_term.put(@pt_by_code, Map.new(countries, &{&1.code, &1.name}))
    end

    :ok
  end

  defp default_path do
    :flux_vale
    |> :code.priv_dir()
    |> Path.join("data/countries.yaml")
  end

  defp normalize_entry(entry) do
    %{code: entry["code"], name: entry["name"]}
  end
end

# The generator for apps/platform/priv/data/countries.yaml (#364).
# Source: the Debian iso-codes database's ISO 3166-1 table — the
# ISO-maintained list of officially assigned alpha-2 codes with
# English short names. Verifies count (249), uniqueness, and the
# sort before writing; FluxVale.Billing.CountriesTest pins all three.
#
# Run from apps/platform:  mix run ../../scripts/generate_countries.exs

source = "/usr/share/iso-codes/json/iso_3166-1.json"
out = Path.join(File.cwd!(), "priv/data/countries.yaml")

entries =
  source
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("3166-1")
  |> Enum.map(fn e -> %{"code" => e["alpha_2"], "name" => e["name"]} end)

# Sort key: case-folded, accent-folded English name (Åland sorts as
# "aland", Côte d'Ivoire as "cote d'ivoire") — a list a human scans
# by typing the letters they'd type. Codepoints, not graphemes: a
# decomposed å is one grapheme cluster ("a" + combining ring).
fold = fn name ->
  name
  |> String.downcase()
  |> String.normalize(:nfd)
  |> String.codepoints()
  |> Enum.reject(fn g ->
    case g do
      <<cp::utf8>> -> cp in 0x0300..0x036F
      _ -> false
    end
  end)
  |> Enum.join()
end

entries = Enum.sort_by(entries, &fold.(&1["name"]))

# --- verify before writing anything ---
count = length(entries)
codes = Enum.map(entries, & &1["code"])
names = Enum.map(entries, & &1["name"])

:ok =
  if count == 249 do
    :ok
  else
    raise "expected 249 officially assigned alpha-2 codes, got #{count}"
  end

:ok = if Enum.uniq(codes) == codes, do: :ok, else: raise("duplicate alpha-2 codes")

:ok =
  if Enum.all?(codes, &Regex.match?(~r/^[A-Z]{2}$/, &1)),
    do: :ok,
    else: raise("non-alpha-2 code present")

:ok = if Enum.uniq(names) == names, do: :ok, else: raise("duplicate names")

:ok =
  if Enum.all?(entries, fn e -> e["code"] != e["name"] end) and Enum.all?(names, &(&1 != "")),
    do: :ok,
    else: raise("bad name")

for c <- ["PH", "DE", "US", "GB"] do
  IO.puts("contains #{c}: #{inspect(Enum.find(entries, &(&1["code"] == c)))}")
end

first = List.first(entries)
last = List.last(entries)

IO.puts(
  "count: #{count}; first: #{first["code"]} #{first["name"]}; last: #{last["code"]} #{last["name"]}"
)

# --- write the YAML ---
header = """
# The country list for the top-up wizard's searchable
# country control [#364]: ISO 3166-1 alpha-2 code + English short
# name, the complete set of officially assigned codes [249 entries],
# sorted by accent-folded English name. Read by
# FluxVale.Billing.Countries — the dropdown's dataset, NOT the tax
# rate table [rates live in priv/repo/seeds/tax_rates.yaml and the
# two are never derived from each other].
#
# Generated from the Debian iso-codes project's ISO 3166-1 JSON
# [/usr/share/iso-codes/json/iso_3166-1.json, 2026-11] by
# scripts/generate_countries.exs — regenerate, never hand-edit: the
# count, uniqueness, and sort order are verified in
# FluxVale.Billing.CountriesTest.
"""

yaml =
  entries
  |> Enum.map(fn e ->
    ~s(  - code: #{e["code"]}\n    name: "#{String.replace(e["name"], "\"", "\\\"")}")
  end)
  |> Enum.join("\n")

File.mkdir_p!(Path.dirname(out))
File.write!(out, header <> "\n" <> yaml <> "\n")
IO.puts("wrote #{out} (#{String.graphemes(File.read!(out)) |> length()} chars)")

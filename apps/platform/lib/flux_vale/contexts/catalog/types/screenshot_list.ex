defmodule FluxVale.Catalog.Types.ScreenshotList do
  @moduledoc """
  An App's real-UI screenshots (#611, plan §4.1) — the "in action"
  section's proof, captured from our own instances (D2: never upstream
  marketing shots):

    * `src` — app-absolute path under `/images/catalog/`, `.png` or
      `.webp` (assets committed under
      `apps/platform/priv/static/images/catalog/<slug>/`)
    * `alt` — required, 10-140 chars. Accessibility is validation, not
      an afterthought.
    * `caption` — optional, max 160 chars

  1-4 items; `[]` is the designed absent state (plan §5: omission
  renders nothing, no placeholder). Like `FirstRunContract`: casting
  and validation live here so seeds, AshAdmin, and the API enforce one
  contract. In memory a list of atom-keyed maps; in storage a Postgres
  array of jsonb (`jsonb[]`, `storage_type {:array, :map}`) holding
  string-keyed maps — `cast_stored/1` re-casts on every read. Prose
  fields reject em dashes and semicolons (D10, `CopyRules`).
  """

  use Ash.Type

  alias FluxVale.Catalog.Types.CopyRules
  alias FluxVale.Catalog.Types.KnownFields

  @known_fields MapSet.new(~w(src alt caption)a)
  @field_atoms Map.new(@known_fields, &{Atom.to_string(&1), &1})
  @src_format ~r{^/images/catalog/.+\.(png|webp)$}
  @min_items 1
  @max_items 4

  @impl Ash.Type
  def storage_type(_constraints), do: {:array, :map}

  @impl Ash.Type
  # The attribute is []-defaulted, never nil; nil only arrives as an
  # explicit clear (YAML null / an admin form) — both mean absence.
  def cast_input(nil, _constraints), do: {:ok, []}

  def cast_input(input, _constraints) when is_list(input), do: new(input)

  def cast_input(_other, _constraints), do: {:error, "expected a list of screenshots"}

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, []}

  def dump_to_native(items, _constraints) when is_list(items),
    do: {:ok, Enum.map(items, &dump_item/1)}

  def dump_to_native(_other, _constraints), do: {:error, "expected a list of screenshots"}

  # Rows that predate the column read NULL — that is the absent state,
  # [] (the FirstRunContract nil-arm stance, plus the [] contract).
  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, []}

  def cast_stored(items, _constraints) when is_list(items), do: cast_input(items, [])

  def cast_stored(_other, _constraints), do: {:error, "expected a list of screenshots"}

  @doc """
  Casts a list of input maps (string keys — YAML/JSON/Admin forms — or
  the items' own atom keys) into validated atom-keyed items. `[]`
  passes; 1-4 items otherwise. An invalid item halts naming the field.
  """
  @spec new(list()) :: {:ok, [map()]} | {:error, String.t()}
  def new(items) when is_list(items) do
    with :ok <- check_item_count(items) do
      cast_items(items)
    end
  end

  def new(_other), do: {:error, "expected a list of screenshots"}

  defp check_item_count(items) do
    count = length(items)

    # 0 is the absent state (plan §5), so only the cap can fail.
    if count <= @max_items do
      :ok
    else
      {:error, "expected #{@min_items}-#{@max_items} screenshots, got #{count}"}
    end
  end

  defp cast_items(items) do
    case Enum.reduce_while(items, {:ok, []}, &cast_item/2) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _message} = error -> error
    end
  end

  defp cast_item(item, {:ok, acc}) when is_map(item) do
    case cast_one(item) do
      {:ok, cast} -> {:cont, {:ok, [cast | acc]}}
      {:error, _message} = error -> {:halt, error}
    end
  end

  defp cast_item(item, _acc),
    do: {:halt, {:error, "each screenshot must be a map, got: #{inspect(item)}"}}

  defp cast_one(item) do
    with {:ok, item} <- normalize_keys(item),
         :ok <- KnownFields.reject(item, @known_fields),
         {:ok, src} <- cast_src(item),
         {:ok, alt} <- cast_alt(item),
         {:ok, caption} <- cast_caption(item) do
      {:ok, %{src: src, alt: alt, caption: caption}}
    end
  end

  # String → atom for known field names only; unknown names pass
  # through as strings so KnownFields.reject/2 reports them.
  defp normalize_keys(item) do
    initial = {:ok, %{}}

    Enum.reduce_while(item, initial, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, Map.get(@field_atoms, key, key), value)}}

      {key, _value}, _acc ->
        {:halt, {:error, "screenshot keys must be strings or atoms, got: #{inspect(key)}"}}
    end)
  end

  defp cast_src(item) do
    case Map.fetch(item, :src) do
      {:ok, src} when is_binary(src) ->
        if src =~ @src_format,
          do: {:ok, src},
          else:
            {:error,
             "src must be an app-absolute path like /images/catalog/<slug>/shot.webp, got: #{inspect(src)}"}

      {:ok, other} ->
        {:error, "src must be a path string, got: #{inspect(other)}"}

      :error ->
        {:error, "src is required"}
    end
  end

  defp cast_alt(item) do
    case Map.fetch(item, :alt) do
      {:ok, alt} when is_binary(alt) ->
        CopyRules.bounded(:alt, alt, 10, 140)

      {:ok, other} ->
        {:error, "alt must be a string, got: #{inspect(other)}"}

      :error ->
        {:error, "alt is required"}
    end
  end

  # Absence is optional (no caption); a present value must be a
  # non-empty bounded string (the cast_optional_env stance).
  defp cast_caption(item) do
    case Map.fetch(item, :caption) do
      {:ok, nil} -> {:ok, nil}
      :error -> {:ok, nil}
      {:ok, caption} when is_binary(caption) -> CopyRules.bounded(:caption, caption, 1, 160)
      {:ok, other} -> {:error, "caption must be a string or null, got: #{inspect(other)}"}
    end
  end

  # Storage form — a string-keyed map per item (jsonb round-trip;
  # atoms don't survive). caption omits when nil (the put_if_present
  # stance for optional fields).
  defp dump_item(%{src: src, alt: alt, caption: caption}) do
    %{}
    |> Map.put("src", src)
    |> Map.put("alt", alt)
    |> put_if_present("caption", caption)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end

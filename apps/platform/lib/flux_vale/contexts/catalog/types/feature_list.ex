defmodule FluxVale.Catalog.Types.FeatureList do
  @moduledoc """
  An App's feature cards (#611, plan §4.1) — the 2x2 "what you can do
  with {app}" grid's app-authored capabilities:

    * `icon` — one name from the exported allowlist (`icons/0`), the
      full `<.icon name>` form (e.g. `"hero-archive-box"`). The
      allowlist is the one list the renderer derives from, so a bad
      icon fails the seed, not the page (plan §4.3).
    * `title` — 3-60 chars
    * `body` — 20-220 chars

  1-4 items (the grid's 2x2 shape caps it); `[]` is the designed
  absent state (plan §5). Like `FirstRunContract`: casting and
  validation live here so seeds, AshAdmin, and the API enforce one
  contract. In memory a list of atom-keyed maps; in storage a Postgres
  array of jsonb (`jsonb[]`, `storage_type {:array, :map}`) holding
  string-keyed maps — `cast_stored/1` re-casts on every read. Prose
  fields reject em dashes and semicolons (D10, `CopyRules`).
  """

  use Ash.Type

  alias FluxVale.Catalog.Types.CopyRules
  alias FluxVale.Catalog.Types.KnownFields

  @known_fields MapSet.new(~w(icon title body)a)
  @field_atoms Map.new(@known_fields, &{Atom.to_string(&1), &1})
  @min_items 1
  @max_items 4

  # The small consistent heroicons (v2.2.0 outline) set the feature
  # grid draws from — every name exists in the pinned dep and renders
  # through the existing `<.icon>` component. Widening the set is a
  # deliberate diff here, so the page can never reference a missing
  # icon.
  @icons ~w(
    hero-archive-box
    hero-arrow-path
    hero-bolt
    hero-book-open
    hero-calculator
    hero-chart-bar
    hero-chat-bubble-left-right
    hero-code-bracket
    hero-device-phone-mobile
    hero-document-text
    hero-finger-print
    hero-key
    hero-magnifying-glass
    hero-photo
    hero-share
    hero-shield-check
    hero-tag
    hero-user-group
  )

  @doc """
  The icon allowlist, `FirstRunContract.known_patterns/0`'s stance: the
  renderer (S4) derives its icon choices from this one list, so an icon
  added here can never sit outside the page's reach.
  """
  @spec icons() :: [String.t()]
  def icons, do: @icons

  @impl Ash.Type
  def storage_type(_constraints), do: {:array, :map}

  @impl Ash.Type
  # The attribute is []-defaulted, never nil; nil only arrives as an
  # explicit clear (YAML null / an admin form) — both mean absence.
  def cast_input(nil, _constraints), do: {:ok, []}

  def cast_input(input, _constraints) when is_list(input), do: new(input)

  def cast_input(_other, _constraints), do: {:error, "expected a list of feature cards"}

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, []}

  def dump_to_native(items, _constraints) when is_list(items),
    do: {:ok, Enum.map(items, &dump_item/1)}

  def dump_to_native(_other, _constraints), do: {:error, "expected a list of feature cards"}

  # Rows that predate the column read NULL — that is the absent state,
  # [] (the FirstRunContract nil-arm stance, plus the [] contract).
  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, []}

  def cast_stored(items, _constraints) when is_list(items), do: cast_input(items, [])

  def cast_stored(_other, _constraints), do: {:error, "expected a list of feature cards"}

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

  def new(_other), do: {:error, "expected a list of feature cards"}

  defp check_item_count(items) do
    count = length(items)

    # 0 is the absent state (plan §5), so only the cap can fail.
    if count <= @max_items do
      :ok
    else
      {:error, "expected #{@min_items}-#{@max_items} feature cards, got #{count}"}
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

  defp cast_item(item, _acc) do
    {:halt, {:error, "each feature card must be a map, got: #{inspect(item)}"}}
  end

  defp cast_one(item) do
    with {:ok, item} <- normalize_keys(item),
         :ok <- KnownFields.reject(item, @known_fields),
         {:ok, icon} <- cast_icon(item),
         {:ok, title} <- cast_title(item),
         {:ok, body} <- cast_body(item) do
      {:ok, %{icon: icon, title: title, body: body}}
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
        {:halt, {:error, "feature card keys must be strings or atoms, got: #{inspect(key)}"}}
    end)
  end

  defp cast_icon(item) do
    case Map.fetch(item, :icon) do
      {:ok, icon} when is_binary(icon) ->
        if icon in @icons,
          do: {:ok, icon},
          else: {:error, unknown_icon(icon)}

      {:ok, other} ->
        {:error, "icon must be one of the allowlisted heroicons, got: #{inspect(other)}"}

      :error ->
        {:error, "icon is required"}
    end
  end

  defp unknown_icon(icon),
    do: "unknown icon #{inspect(icon)}. Supported: #{inspect(Enum.sort(@icons))}"

  defp cast_title(item) do
    case Map.fetch(item, :title) do
      {:ok, title} when is_binary(title) ->
        CopyRules.bounded(:title, title, 3, 60)

      {:ok, other} ->
        {:error, "title must be a string, got: #{inspect(other)}"}

      :error ->
        {:error, "title is required"}
    end
  end

  defp cast_body(item) do
    case Map.fetch(item, :body) do
      {:ok, body} when is_binary(body) ->
        CopyRules.bounded(:body, body, 20, 220)

      {:ok, other} ->
        {:error, "body must be a string, got: #{inspect(other)}"}

      :error ->
        {:error, "body is required"}
    end
  end

  # Storage form — a string-keyed map per item (jsonb round-trip;
  # atoms don't survive).
  defp dump_item(%{icon: icon, title: title, body: body}) do
    %{}
    |> Map.put("icon", icon)
    |> Map.put("title", title)
    |> Map.put("body", body)
  end
end

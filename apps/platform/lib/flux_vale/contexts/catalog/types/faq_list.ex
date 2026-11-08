defmodule FluxVale.Catalog.Types.FaqList do
  @moduledoc """
  An App's own FAQ items (#611, plan §4.1) — the app-specific
  objections the generated FAQ cannot answer (SSH support, licensing,
  multi-user shape), appended to the generated columns:

    * `question` — 8-120 chars, ending in `?` (it renders as a
      `<summary>`; it must read as a question)
    * `answer` — 20-600 chars

  1-4 items; `[]` is the designed absent state (plan §5). Like
  `FirstRunContract`: casting and validation live here so seeds,
  AshAdmin, and the API enforce one contract. In memory a list of
  atom-keyed maps; in storage a Postgres array of jsonb (`jsonb[]`,
  `storage_type {:array, :map}`) holding string-keyed maps —
  `cast_stored/1` re-casts on every read. Both fields reject em dashes
  and semicolons (D10, `CopyRules`).
  """

  use Ash.Type

  alias FluxVale.Catalog.Types.CopyRules
  alias FluxVale.Catalog.Types.KnownFields

  @known_fields MapSet.new(~w(question answer)a)
  @field_atoms Map.new(@known_fields, &{Atom.to_string(&1), &1})
  @min_items 1
  @max_items 4

  @impl Ash.Type
  def storage_type(_constraints), do: {:array, :map}

  @impl Ash.Type
  # The attribute is []-defaulted, never nil; nil only arrives as an
  # explicit clear (YAML null / an admin form) — both mean absence.
  def cast_input(nil, _constraints), do: {:ok, []}

  def cast_input(input, _constraints) when is_list(input), do: new(input)

  def cast_input(_other, _constraints), do: {:error, "expected a list of FAQ items"}

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, []}

  def dump_to_native(items, _constraints) when is_list(items),
    do: {:ok, Enum.map(items, &dump_item/1)}

  def dump_to_native(_other, _constraints), do: {:error, "expected a list of FAQ items"}

  # Rows that predate the column read NULL — that is the absent state,
  # [] (the FirstRunContract nil-arm stance, plus the [] contract).
  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, []}

  def cast_stored(items, _constraints) when is_list(items), do: cast_input(items, [])

  def cast_stored(_other, _constraints), do: {:error, "expected a list of FAQ items"}

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

  def new(_other), do: {:error, "expected a list of FAQ items"}

  defp check_item_count(items) do
    count = length(items)

    # 0 is the absent state (plan §5), so only the cap can fail.
    if count <= @max_items do
      :ok
    else
      {:error, "expected #{@min_items}-#{@max_items} FAQ items, got #{count}"}
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
    do: {:halt, {:error, "each FAQ item must be a map, got: #{inspect(item)}"}}

  defp cast_one(item) do
    with {:ok, item} <- normalize_keys(item),
         :ok <- KnownFields.reject(item, @known_fields),
         {:ok, question} <- cast_question(item),
         {:ok, answer} <- cast_answer(item) do
      {:ok, %{question: question, answer: answer}}
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
        {:halt, {:error, "FAQ item keys must be strings or atoms, got: #{inspect(key)}"}}
    end)
  end

  defp cast_question(item) do
    case Map.fetch(item, :question) do
      {:ok, question} when is_binary(question) ->
        with {:ok, question} <- CopyRules.bounded(:question, question, 8, 120),
             :ok <- check_question_mark(question) do
          {:ok, question}
        end

      {:ok, other} ->
        {:error, "question must be a string, got: #{inspect(other)}"}

      :error ->
        {:error, "question is required"}
    end
  end

  # A FAQ row renders as a <summary> toggle — the copy reads as a
  # question or the page reads broken.
  defp check_question_mark(question) do
    if String.ends_with?(question, "?") do
      :ok
    else
      {:error, "question must end with a question mark, got: #{inspect(question)}"}
    end
  end

  defp cast_answer(item) do
    case Map.fetch(item, :answer) do
      {:ok, answer} when is_binary(answer) ->
        CopyRules.bounded(:answer, answer, 20, 600)

      {:ok, other} ->
        {:error, "answer must be a string, got: #{inspect(other)}"}

      :error ->
        {:error, "answer is required"}
    end
  end

  # Storage form — a string-keyed map per item (jsonb round-trip;
  # atoms don't survive).
  defp dump_item(%{question: question, answer: answer}) do
    %{}
    |> Map.put("question", question)
    |> Map.put("answer", answer)
  end
end

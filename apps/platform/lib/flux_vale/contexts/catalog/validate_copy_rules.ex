defmodule FluxVale.Catalog.ValidateCopyRules do
  @moduledoc """
  D10 for the curated fields the map-shaped types don't cover (#611
  plan §4.3): App `caveats`/`alternatives` items and
  `in_action_intro`, Category `audience`, AppVersion `release_notes`
  (#678) — plain strings, or lists of them, that must obey `CopyRules`
  at write time so seeds, admin, and the API enforce the same copy
  rules the typed lists already carry. Only fields being changed are
  checked: stored text was validated at its own write.
  """

  use Ash.Resource.Validation

  alias Ash.Changeset
  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Resource.Validation
  alias FluxVale.Catalog.Types.CopyRules

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, opts, _context) do
    errors = Enum.flat_map(opts[:fields], &field_errors(changeset, &1))

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  defp field_errors(changeset, field) do
    case Changeset.fetch_change(changeset, field) do
      {:ok, value} -> value_errors(field, value)
      :error -> []
    end
  end

  # nil is the absent state (plan §5); a list is checked per item
  # (caveats, alternatives), a bare string once.
  defp value_errors(_field, nil), do: []

  defp value_errors(field, values) when is_list(values),
    do: Enum.flat_map(values, &value_errors(field, &1))

  defp value_errors(field, value) when is_binary(value) do
    case CopyRules.check(field, value) do
      :ok -> []
      {:error, message} -> [InvalidAttribute.exception(field: field, message: message)]
    end
  end

  # Defensive arm: the string/array casts reject every other shape
  # before a validation runs, so this can't fire in a test.
  # coveralls-ignore-next-line
  defp value_errors(field, other),
    do: [
      InvalidAttribute.exception(
        field: field,
        message: "must be a string or list of strings, got: #{inspect(other)}"
      )
    ]

  @impl Validation
  # Trivial callback — string scanning, no atomic expression (same
  # stance as ValidateFirstRunEnv).
  # coveralls-ignore-next-line
  def atomic?, do: false
end

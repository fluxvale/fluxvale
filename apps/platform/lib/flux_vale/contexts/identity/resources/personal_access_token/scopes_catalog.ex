defmodule FluxVale.Identity.PersonalAccessToken.ScopesCatalog do
  @moduledoc """
  Guards `:scopes` against the S1 catalog (#360): every entry must be
  a grantable scope and appear at most once.

  The mint operation validates the same list before generating
  anything; this is the resource-level backstop so no caller can
  bypass the operation and write an off-catalog scope to a row.
  """

  use Ash.Resource.Validation

  alias FluxVale.Api.Scopes

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    scopes = Ash.Changeset.get_attribute(changeset, :scopes) || []

    cond do
      duplicate = find_duplicate(scopes) ->
        {:error, field: :scopes, message: "duplicate scope #{duplicate}"}

      invalid = Enum.find(scopes, &(not Scopes.valid_scope?(&1))) ->
        {:error, field: :scopes, message: "unknown scope #{invalid}"}

      true ->
        :ok
    end
  end

  defp find_duplicate(scopes) do
    Enum.find(scopes, fn scope -> Enum.count(scopes, &(&1 == scope)) > 1 end)
  end
end

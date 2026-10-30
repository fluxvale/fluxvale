defmodule FluxVale.Identity.User.ValidUsername do
  @moduledoc """
  The `:set_username` action's format gate (#285 T5) — a thin Ash
  validation over DeriveUsername's rule set (`format_problem/1`), so the
  rename and the signup derivation cannot drift apart: one regex, one
  reserved list. Uniqueness stays the `unique_username` identity's job.
  """

  use Ash.Resource.Validation

  alias Ash.Resource.Validation
  alias FluxVale.Identity.User.DeriveUsername

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    username = Ash.Changeset.get_argument_or_attribute(changeset, :username)

    case DeriveUsername.format_problem(username) do
      nil -> :ok
      problem -> {:error, field: :username, message: problem}
    end
  end
end

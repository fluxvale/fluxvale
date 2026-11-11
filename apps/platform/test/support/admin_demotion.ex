defmodule FluxVale.TestSupport.AdminDemotion do
  @moduledoc false

  # Demote a platform admin under a live session — the generated-tools
  # demotion suites' data-layer idiom (User carries no role-write
  # action and Ash.Seed is create-only, so the precondition rides the
  # row directly; tests own their preconditions, the gates are what
  # the suites pin). Older admin suites keep their own private copies
  # of this shape; they migrate here when touched, not in bulk.
  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  @spec demote!(FluxVale.Identity.User.t()) :: :ok
  def demote!(admin) do
    query = from(u in "users", where: u.id == ^Ecto.UUID.dump!(admin.id))
    {updated, nil} = FluxVale.Repo.update_all(query, set: [platform_role: "user"])
    assert updated == 1
    :ok
  end
end

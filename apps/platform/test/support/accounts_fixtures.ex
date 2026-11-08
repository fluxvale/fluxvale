defmodule FluxVale.TestSupport.AccountsFixtures do
  @moduledoc """
  Preconditions for Accounts-coupled tests (#119): a user — whose personal
  org the `User.create` JIT change provisions — and that org, read back
  through actions with `authorize?: false` (the repo's bootstrap posture,
  mirroring seeds).
  """

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  @doc """
  Creates a user via the create action; the JIT change provisions the
  personal org as a side effect. `local_part` pins the derived username,
  which carries the org's name and slug base — callers needing colliding
  handles pass the same local part with a colliding domain, or generate
  their own addresses.
  """
  @spec user!(String.t() | nil) :: User.t()
  def user!(local_part \\ nil) do
    email = "#{local_part || "user-#{System.unique_integer([:positive])}"}@fluxvale.test"

    User.create!(email, %{}, authorize?: false)
  end

  @doc "A platform admin through the create action (the admin suites' actor)."
  @spec admin!(String.t() | nil) :: User.t()
  def admin!(local_part \\ nil) do
    email = "#{local_part || "admin-#{System.unique_integer([:positive])}"}@fluxvale.test"

    User.create!(email, %{platform_role: :admin}, authorize?: false)
  end

  @doc """
  The user's verified primary address (#287: the users table carries no
  address — this reads the signup row). For action-created users only;
  a nil answer is data drift and fails the caller's next assert.
  """
  @spec primary_address!(User.t()) :: String.t()
  def primary_address!(%User{} = user) do
    row =
      UserEmail
      |> Ash.Query.filter(user_id == ^user.id and is_primary and not is_nil(verified_at))
      |> Ash.read_one!(authorize?: false)

    to_string(row.address)
  end

  @doc """
  The user's one address row, whatever its state — the signup row for
  live accounts, the reservation for invited ones (#287: invited
  accounts hold exactly one pending row; `primary_address!/1` would
  miss it).
  """
  @spec any_address!(User.t()) :: String.t()
  def any_address!(%User{} = user) do
    [row | _] =
      UserEmail
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!(authorize?: false)

    to_string(row.address)
  end

  @doc "The user's personal org (loud failure if JIT provisioning didn't run)."
  @spec personal_org!(User.t()) :: FluxVale.Accounts.Organization.t()
  def personal_org!(%User{} = user) do
    {:ok, org} = Accounts.personal_org_for_user(user.id, authorize?: false)
    org
  end

  @doc """
  A REAL (non-personal) org the user owns — the org-surface tests' host
  since S5: the personal org no longer renders org pages (its URLs
  redirect to the personal account's surfaces), so tests exercising
  those pages ride a real org. Org + `:owner` membership ride the
  actions with `authorize?: false` — the bootstrap posture, mirroring
  seeds (system writers only; the actor-reachable `create_with_owner`
  path exists but these preconditions stay authorize-free).
  """
  @spec owned_org!(User.t()) :: FluxVale.Accounts.Organization.t()
  def owned_org!(%User{} = user) do
    n = System.unique_integer([:positive])

    org =
      Organization.create!(%{name: "Org #{n}", slug: "org-#{n}"}, authorize?: false)

    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :owner},
      authorize?: false
    )

    org
  end

  @doc """
  A platform admin (`platform_role: :admin`) for policy-test actors.
  The email is keyed to the calling test process: stable inside one
  test (a second call converges on the same row) and distinct across
  concurrent tests, whose sandbox transactions cannot see each
  other's uncommitted rows. A shared fixed address deadlocked here:
  two async suites missing the same get-or-create read raced one
  insert through the JIT provisioning's multi-table writes and took
  the unique-index waits into a 40P01. Bootstrap posture: the
  precondition runs `authorize?: false`. The admin policy itself is
  under test in the wallet/policy suites.
  """
  @spec platform_admin!() :: User.t()
  def platform_admin! do
    pid = inspect(self())
    key = String.replace(pid, ~r/[^0-9]/, "")
    email = "admin-#{key}@fluxvale.test"

    case User.get_by_email(email, authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!(email, %{platform_role: :admin}, authorize?: false)
    end
  end

  @doc """
  Attaches a VERIFIED PRIMARY user_emails row for `address` to a
  hand-seeded user — the end state the create path gives every
  action-created account (#287: seed! cannot write user_emails, and
  the users table carries no address — the address is an argument to
  this seam because it lives nowhere else).
  """
  @spec attach_primary_email!(User.t(), String.t()) :: UserEmail.t()
  def attach_primary_email!(%User{} = user, address) do
    {:ok, row} = UserEmail.add(address, %{user: user}, authorize?: false)
    {:ok, verified} = UserEmail.mark_verified(row, authorize?: false)
    {:ok, primary} = UserEmail.set_primary(verified, actor: user)
    primary
  end
end

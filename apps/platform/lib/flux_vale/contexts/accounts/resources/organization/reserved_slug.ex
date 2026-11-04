defmodule FluxVale.Accounts.Organization.ReservedSlug do
  @moduledoc """
  The org-slug reservation list (#408): the platform's own path
  identities (`/docs`, `/billing`, …) are never claimable through the
  actor-created flow. Wired on `:create_with_owner` only — the JIT
  provisioning path derives slugs from usernames upstream, and rename
  keeps its no-reservations behavior (the accepted asymmetry; revisit
  trigger: the invite flow, when org slugs start being shareable).
  """

  use Ash.Resource.Validation

  # The #408-decided reservation set — NOT a mechanical mirror of the
  # router's served first segments (pricing, auth, sign-in serve today
  # but stay unreserved; docs, status are reserved though unserved).
  # Reservations never evict claimed slugs — gaps set now are permanent.
  # "new" is here for the literal /organizations/new route (definition
  # order makes the literal beat :slug): reserving it keeps the
  # actor-create path from minting an org at the creation page's own
  # address. Rename and the JIT signup path can still land an org on a
  # reserved word — such an org's home serves the literal, so its
  # switcher row rides into the creation page and no redirect ships.
  # Revisit trigger: the day org slugs claim root-level surfaces.
  #
  # Signup provisioning predates and bypasses the list: a signup whose
  # username is a reserved word claims it (the JIT path derives slugs
  # upstream and never runs this validation).
  @reserved ~w(www app api admin blog catalog docs apps instances billing settings organizations support status mail fluxvale new)

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    slug = Ash.Changeset.get_argument_or_attribute(changeset, :slug)

    if slug in @reserved do
      {:error, field: :slug, message: "is reserved"}
    else
      :ok
    end
  end
end

defmodule FluxVale.Accounts.Organization.ReservedSlug do
  @moduledoc """
  The org-slug reservation list (#408): non-admin actors cannot claim
  the platform's own path identities (`/docs`, `/billing`, …) through
  the actor-created flow. Platform admins are exempt (#754) — the
  reservation fences brand-surface claims, not the operator minting the
  company org. Wired on `:create_with_owner` only — the JIT
  provisioning path derives slugs from usernames upstream, and rename
  keeps its no-reservations behavior (the accepted asymmetry; revisit
  trigger: the invite flow, when org slugs start being shareable).
  """

  use Ash.Resource.Change

  alias FluxVale.Checks.ActorIsPlatformAdmin

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
  # upstream and never runs this change).
  @reserved ~w(www app api admin blog catalog docs apps instances billing settings organizations support status mail fluxvale new)

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # Read in a before_action hook, not change/3's context: for_create/4
    # runs changes before Ash.create/2 can attach an actor (the
    # create_with_owner membership change reads it the same way).
    Ash.Changeset.before_action(changeset, fn changeset ->
      slug = Ash.Changeset.get_argument_or_attribute(changeset, :slug)
      actor = changeset.context[:private][:actor]

      if slug in @reserved and not ActorIsPlatformAdmin.platform_admin?(actor) do
        Ash.Changeset.add_error(changeset, field: :slug, message: "is reserved")
      else
        changeset
      end
    end)
  end
end

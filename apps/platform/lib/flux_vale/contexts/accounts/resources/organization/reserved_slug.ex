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
  # but stay unreserved; docs, status are reserved though unserved). No
  # live collision while org slugs ride /organizations/:slug only, and
  # reservations never evict claimed slugs — so gaps set now are
  # permanent. Revisit trigger: the day org slugs claim root-level
  # surfaces.
  @reserved ~w(www app api admin blog catalog docs apps instances billing settings organizations support status mail fluxvale)

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

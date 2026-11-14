defmodule FluxVale.Accounts.Organization.ReservedSlug do
  @moduledoc """
  The org-slug reservation list (#408): actors cannot claim the
  platform's own path identities (`/docs`, `/billing`, …) through the
  actor-created flow. Platform admins are exempt for brand surfaces
  (#754) — the reservation fences brand-surface claims, not the
  operator minting the company org — but never for route sentinels
  (`new`), and never through the machine API (ADR-0047 D3). Wired on
  `:create_with_owner` only — the JIT provisioning path derives slugs
  from usernames upstream, and rename keeps its no-reservations
  behavior (the accepted asymmetry; revisit trigger: the invite flow,
  when org slugs start being shareable).
  """

  use Ash.Resource.Change

  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Checks.CallOutsideMachineApi

  # The #408-decided reservation set — NOT a mechanical mirror of the
  # router's served first segments (pricing, auth, sign-in serve today
  # but stay unreserved; docs, status are reserved though unserved).
  # Reservations never evict claimed slugs — gaps set now are permanent.
  #
  # Brand surfaces: path identities the platform owns. A platform admin
  # may mint one through the console (#754) — the operator creating the
  # company org is the case the fence is not for. The exemption stops at
  # the machine API (ADR-0047 D3): a PAT is never an operator act.
  @brand_reserved ~w(www app api admin blog catalog docs apps instances billing settings organizations support status mail fluxvale)

  # Route sentinels: literals that beat :slug by definition order, so an
  # org minted here could never render its home — every actor keeps the
  # refusal, admins included. "new" is the literal /organizations/new
  # creation page's word. Rename and the JIT signup path can still land
  # an org on a reserved word — such an org's home serves the literal,
  # so its switcher row rides into the creation page and no redirect
  # ships. Revisit trigger: the day org slugs claim root-level surfaces.
  @route_sentinels ~w(new)

  # Signup provisioning predates and bypasses the list: a signup whose
  # username is a reserved word claims it (the JIT path derives slugs
  # upstream and never runs this change).
  @reserved @brand_reserved ++ @route_sentinels

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # Read in a before_action hook, not change/3's context: for_create/4
    # runs changes before Ash.create/2 can attach an actor (the
    # create_with_owner membership change reads it the same way).
    Ash.Changeset.before_action(changeset, fn changeset ->
      slug = Ash.Changeset.get_argument_or_attribute(changeset, :slug)
      actor = changeset.context[:private][:actor]

      admin_exempt? =
        slug in @brand_reserved and ActorIsPlatformAdmin.platform_admin?(actor) and
          not CallOutsideMachineApi.machine_api?()

      if slug in @reserved and not admin_exempt? do
        Ash.Changeset.add_error(changeset, field: :slug, message: "is reserved")
      else
        changeset
      end
    end)
  end
end

defmodule FluxVale.Infrastructure.Types.AccessDomainKind do
  @moduledoc """
  Who owns a domain row (ADR-0040):

  - `:platform` — FluxVale's own serving domain
    (`config :flux_vale, :instances_base_domain`): one per org,
    system-minted with the org's first instance, born `:verified` (the
    fleet wildcard already covers it — no issuance to wait for) and
    never billed.
  - `:custom` — the owner's own domain, member-registered through
    `Operations.RegisterAccessDomain` and verified by issuance
    (verify-by-issuance).

  The kind is the behavior switch downstream: only `:custom` rows ride
  the issuance ladder, and only `:custom` rows are removable.
  `:text`-stored like every other enum here.
  """

  use Ash.Type.Enum, values: [:platform, :custom]
end

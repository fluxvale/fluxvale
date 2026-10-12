defmodule FluxVale.Accounts.Types.MembershipRole do
  @moduledoc """
  Org-scoped membership roles — a **separate axis** from
  `FluxVale.Identity.Types.PlatformRole` (staff standing) that must never
  be conflated with it.

  `:owner` is the only role provisioning creates today (#119); `:member`
  marks the expansion point for team features.
  """

  use Ash.Type.Enum, values: [:owner, :member]
end

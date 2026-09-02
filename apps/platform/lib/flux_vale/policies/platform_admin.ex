defmodule FluxVale.Policies.PlatformAdmin do
  @moduledoc """
  Ash policy check: the actor's platform role is `:admin`.

  The single gate behind ADR-0027's admin surfaces (TestInbox #22,
  FeatureFlag/AccessRule mutation #25/#26) — they all authorize through
  this check so the admin notion cannot fork.
  """

  use Ash.Policy.SimpleCheck
  alias FluxVale.Policies

  @impl true
  def describe(_opts), do: "actor is a platform admin"

  @impl true
  def match?(actor, _context, _opts), do: Policies.platform_admin?(actor)
end

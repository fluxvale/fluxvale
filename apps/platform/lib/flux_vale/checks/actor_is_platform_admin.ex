defmodule FluxVale.Checks.ActorIsPlatformAdmin do
  @moduledoc """
  Policy check: the actor's platform role is `:admin`.

  The single gate behind ADR-0027's admin surfaces (TestInbox #22,
  FeatureFlag/AccessRule mutation #25/#26) — policy-land and plug-land both
  answer "who is an admin" through this module, so the notion cannot fork.

  Naming convention (codified in apps/platform/AGENTS.md): shared checks live
  under `FluxVale.Checks` and read as actor questions, `Actor<Assertion>`
  — matching the Ash policy guide's example grammar (`ActorIsOldEnough`).
  """

  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor is a platform admin"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, _context, _opts), do: platform_admin?(actor)

  @doc """
  The plug/LiveView-facing predicate — same answer as the policy check.
  """
  @spec platform_admin?(map() | nil) :: boolean()
  def platform_admin?(%{platform_role: :admin}), do: true
  def platform_admin?(_other), do: false
end

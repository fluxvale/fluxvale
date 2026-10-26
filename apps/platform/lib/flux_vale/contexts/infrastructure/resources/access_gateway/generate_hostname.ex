defmodule FluxVale.Infrastructure.AccessGateway.GenerateHostname do
  @moduledoc """
  Mints the gateway's opaque hostname (ADR-0039 §1): `fv-<8 hex>`.

  Opaque is a privacy requirement, not a style: `tailscale serve`'s
  HTTPS certificate puts the node's machine name in the **public CT
  ledger**, so anything derived from the org or the app type leaks to
  anyone reading certificate transparency logs. Eight hex characters
  from a CSPRNG are unguessable and carry no information.

  Generated once, at create, and never re-derived — renaming the node
  in the tailnet console changes its MagicDNS name, which would orphan
  every serve route (a documented Tailscale caveat the onboarding page
  names).
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    name = mint()
    Ash.Changeset.force_change_attribute(changeset, :hostname, name)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line a pure attribute force — nothing to wrap in a transaction
  def atomic?, do: true

  defp mint do
    bytes = :crypto.strong_rand_bytes(4)
    suffix = Base.encode16(bytes, case: :lower)
    "fv-" <> suffix
  end
end

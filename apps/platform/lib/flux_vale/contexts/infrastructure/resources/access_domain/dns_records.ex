defmodule FluxVale.Infrastructure.AccessDomain.DnsRecords do
  @moduledoc """
  The API/panel view of a custom domain's DNS delegation (#783): the
  one `_acme-challenge` CNAME the owner places before registration.
  Derived from the row's domain through
  `AccessDomain.delegation_records/1` — the same function the
  pre-registration preview and the provider's data source use, so the
  row and the preview cannot fork.

  A `:platform` row answers `[]`: the fleet wildcard already covers
  our own domains, and a customer-style delegation would be nonsense.
  """

  use Ash.Resource.Calculation

  alias FluxVale.Infrastructure.AccessDomain

  @impl Ash.Resource.Calculation
  def load(_query, _opts, _context), do: [:domain, :kind]

  @impl Ash.Resource.Calculation
  def calculate(records, _opts, _context) do
    Enum.map(records, fn
      %{kind: :platform} -> []
      %{domain: domain} -> AccessDomain.delegation_records(domain)
    end)
  end
end

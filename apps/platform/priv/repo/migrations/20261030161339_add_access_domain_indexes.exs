defmodule FluxVale.Repo.Migrations.AddAccessDomainIndexes do
  @moduledoc """
  Index backstops for the access-domain registry (review round 1):

  - `access_domains_custom_domain_unique` — the PARTIAL unique index on
    `(domain) WHERE kind = 'custom'`: platform-wide custom-domain
    ownership (two orgs must never hold Certificates for the same
    dnsName). The register validation (EnsureRegistrable) is the front
    door; this constraint is what a race loses on, loudly. Per-org
    `:platform` rows are same-domain by design, hence the partial.
  - `instance_hostnames(instance_id)` — every instance delete cascades
    into hostnames (`on_delete: :delete`); the child-side index keeps
    that scan a lookup.
  """

  use Ecto.Migration

  def up do
    create(
      index(:access_domains, [:domain],
        name: "access_domains_custom_domain_unique",
        unique: true,
        where: "kind = 'custom'"
      )
    )

    create(index(:instance_hostnames, [:instance_id]))
  end

  def down do
    drop_if_exists(index(:instance_hostnames, [:instance_id]))

    drop_if_exists(index(:access_domains, [:domain], name: "access_domains_custom_domain_unique"))
  end
end

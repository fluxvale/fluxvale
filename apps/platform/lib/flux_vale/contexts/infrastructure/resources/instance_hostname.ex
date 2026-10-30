defmodule FluxVale.Infrastructure.InstanceHostname do
  @moduledoc """
  One hostname an instance answers on, under an access domain: `label`
  (`<instance slug>` for the platform domain, a custom label under a
  custom domain's wildcard later) below the domain's name.

  This is the **one source of truth for "which hostnames exist"** —
  S2's edge routes and S4's resolver views consume it, so a hostname
  that exists anywhere else first is a bug: mint here, then derive.

  Rows are system-minted (`:mint`): the instance create path's
  `MintDefaultHostname` puts `<slug>` on the org's platform domain.
  Uniqueness is (access_domain, label) — the same label under one
  domain twice would be a silent hijack of the first row's traffic, so
  the identity below is a boundary, not tidiness. Reads ride the
  instance's policy: a hostname is visible iff its instance is.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Instance

  postgres do
    table("instance_hostnames")
    repo(FluxVale.Repo)

    migration_defaults(id: "nil")

    custom_indexes do
      # Every instance delete cascades here (the reference below is
      # on_delete: :delete) — the child-side index keeps that scan a
      # lookup instead of a table walk.
      index([:instance_id])
    end

    references do
      # The hostname's only reason to exist is its instance — AccessRoute's
      # pairing stance: teardown of the instance takes the row with it, no
      # orphan sweep needed.
      reference(:instance, on_delete: :delete)

      # Restrict, not cascade — the AccessGateway stance: removing a
      # domain with live hostnames must refuse loudly (this constraint
      # IS RemoveAccessDomain's hostname guard — the operation maps its
      # refusal to `:hostnames_present`); a DB cascade would be a
      # silent lie that unroutes serving instances.
      reference(:access_domain, on_delete: :restrict)
    end
  end

  policies do
    # A hostname is visible iff its instance is (the instance's own read
    # policy scopes to org members).
    policy action_type(:read) do
      description("Hostname reads ride the instance's policy")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    # Minted and deleted by the system paths (instance create, re-homing
    # in later slices); members never write a hostname directly.
    policy action_type([:create, :destroy]) do
      description("System-only: MintDefaultHostname owns the writes (authorize?: false)")
      forbid_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    # DNS label below the domain: lowercase alnum + inner hyphens, 1-63
    # chars — ingress.ex's @dns_label grammar NARROWED to the canon we
    # mint: slugs are haikunate-lowercase and every writer downcases
    # first, so uppercase is not a shape this table produces — accepting
    # it would mint rows the S2 edge routes and S4 resolver views must
    # then special-case. The same injection posture as ingress.ex (a
    # label here becomes part of edge route hosts and resolver
    # answers). \z (not $): a trailing newline must not slip through.
    attribute :label, :string do
      allow_nil?(false)
      public?(true)
      constraints(match: ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/)
    end

    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :instance, Instance do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :access_domain, AccessDomain do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :mint do
      description("System-only: mint one hostname under a domain (the instance create path).")
      accept([:instance_id, :access_domain_id, :label])
    end

    destroy :destroy do
      description("System-only: re-homing/deleting a hostname (later slices' re-home path).")
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:mint)
    define(:destroy)
  end

  identities do
    # One label per domain — the traffic-hijack boundary (see moduledoc).
    identity(:unique_label_per_domain, [:access_domain_id, :label])
  end
end

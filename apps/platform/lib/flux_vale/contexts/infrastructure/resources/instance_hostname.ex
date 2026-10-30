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

    references do
      # The hostname's only reason to exist is its instance — AccessRoute's
      # pairing stance: teardown of the instance takes the row with it, no
      # orphan sweep needed.
      reference(:instance, on_delete: :delete)

      # Restrict, not cascade — the AccessGateway stance: removing a
      # domain with live hostnames must refuse loudly
      # (Operations.RemoveAccessDomain's guard); a DB cascade would be a
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
    # chars — ingress.ex's @dns_label grammar, byte for byte (a label
    # here becomes part of edge route hosts and resolver answers, so the
    # same injection posture applies). \z (not $): a trailing newline
    # must not slip through.
    attribute :label, :string do
      allow_nil?(false)
      public?(true)
      constraints(match: ~r/^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/)
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

    read :list_for_domain do
      description("The domain's hostnames — RemoveAccessDomain's guard input")
      argument(:access_domain_id, :uuid, allow_nil?: false)
      filter(expr(access_domain_id == ^arg(:access_domain_id)))
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:mint)
    define(:destroy)
    define(:list_for_domain, args: [:access_domain_id])
  end

  identities do
    # One label per domain — the traffic-hijack boundary (see moduledoc).
    identity(:unique_label_per_domain, [:access_domain_id, :label])
  end
end

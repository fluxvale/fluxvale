defmodule FluxVale.Infrastructure.AccessRoute do
  @moduledoc """
  One attached instance's slot on a gateway (ADR-0039 §3): the pairing
  row that says "this instance is reachable through this gateway at
  this provider-opaque key".

  `route_key` is **provider-opaque** — Tailscale stores the allocated
  port ("8443"); a WireGuard gateway would store a peer/host mapping.
  Nothing outside the provider implementation parses it, so a provider
  swap adds an enum value and a module, never a migration
  (ADR-0039 §2).

  The row is load-bearing in three places, which is why it is a
  resource and not a column on the instance:

  - **Routing** — the provider's serve config is generated from it.
  - **Authorization** — the wake endpoint (ADR-0039 §6) trusts exactly
    this pairing and nothing else; the row IS the owner's consent that
    the gateway may start the instance.
  - **The namespace policy** — the private instance's NetworkPolicy
    admits the gateway's namespace only while a row exists
    (ADR-0039 §3), never the public edge.

  Uniqueness is both ways: one instance has at most one route (attaching
  twice is the same reachability), and one gateway port serves at most
  one instance (two instances on one port is a silent cross-tenant
  leak — the identity below is a security boundary, not tidiness).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("access_routes")
    repo(FluxVale.Repo)

    migration_defaults(id: "nil")

    # Teardown of either end takes the pairing with it: an instance's
    # namespace delete must not leave a route pointing at it, and a
    # gateway's teardown detaches everything first (the operation owns
    # the order, this is the backstop).
    references do
      reference(:gateway, on_delete: :delete)
      reference(:instance, on_delete: :delete)
    end
  end

  policies do
    # Reads ride the gateway's org membership — a route is part of the
    # gateway's configuration surface. Writes are the operations'
    # (AttachInstance / DetachInstance), actorless like every other
    # lifecycle op; members never write a route directly.
    policy action_type(:read) do
      description("Members read their org's routes through the gateway")
      authorize_if(relates_to_actor_via([:gateway, :organization, :members]))
    end

    policy action_type([:create, :destroy]) do
      description(
        "System-only: AttachInstance/DetachInstance own the pairing (authorize?: false)"
      )

      forbid_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :gateway_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    # Provider-opaque (ADR-0039 §2). Tailscale: the HTTPS port as a
    # string. Deliberately a string, not an integer — a WireGuard
    # provider's key is not a port.
    attribute :route_key, :string do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :gateway, FluxVale.Infrastructure.AccessGateway do
      # The FK is `gateway_id`: the resource's own name would mint
      # `access_gateway_id` by convention, and the row is already scoped
      # by its table.
      source_attribute(:gateway_id)
      define_attribute?(false)
      allow_nil?(false)
      public?(true)
    end

    belongs_to :instance, FluxVale.Infrastructure.Instance do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:gateway_id, :instance_id, :route_key])
    end

    destroy :destroy do
      primary?(true)
    end

    read :get_by_instance do
      description("The instance's route (at most one — `unique_instance`)")
      get?(true)
      argument(:instance_id, :uuid, allow_nil?: false)
      filter(expr(instance_id == ^arg(:instance_id)))
    end

    read :list_for_gateway do
      description("The gateway's routes — serve-config generation's input")
      argument(:gateway_id, :uuid, allow_nil?: false)
      filter(expr(gateway_id == ^arg(:gateway_id)))
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:create)
    define(:destroy)
    define(:get_by_instance, args: [:instance_id])
    define(:list_for_gateway, args: [:gateway_id])
  end

  identities do
    # Both directions are security boundaries (see moduledoc).
    identity(:unique_instance, [:instance_id])
    identity(:unique_route_key, [:gateway_id, :route_key])
  end
end

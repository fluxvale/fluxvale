defmodule FluxVale.Infrastructure.InstanceHostname do
  @moduledoc """
  One hostname an instance answers on, under an access domain: `label`
  (`<instance slug>` for the platform domain, a custom label under a
  custom domain's wildcard later) below the domain's name.

  This is the **one source of truth for "which hostnames exist"** —
  S2's edge routes and S4's resolver views consume it, so a hostname
  that exists anywhere else first is a bug: mint here, then derive.

  Rows are system-minted (`:mint`): the instance create path's
  `MintDefaultHostname` puts `<slug>` on the org's platform domain. A
  member mints a custom label under a verified custom domain through
  the `:mint_member` action (the operation seam, `MintCustomHostname`),
  and removes one through `:remove_member` (`RemoveCustomHostname`).
  Uniqueness is (access_domain, label) — the same label under one
  domain twice would be a silent hijack of the first row's traffic, so
  the identity below is a boundary, not tidiness. Reads ride the
  instance's policy: a hostname is visible iff its instance is.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Error.Changes.InvalidArgument
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Instance

  # The wire surface: a hostname is only its identity and where it
  # sits. The domain's name rides the page's loaded relationship, not
  # the row.
  @hostname_fields [:id, :label, :instance_id, :access_domain_id, :created_at]

  # The operation's guard atoms carry no message of their own; give
  # them the owner's plain words (the AccessDomain remove verbs' stance).
  @mint_refusals %{
    different_organization: "that domain belongs to a different organization",
    not_custom: "only a custom domain can host a custom address",
    not_verified: "verify the domain before adding addresses to it"
  }

  @remove_refusals %{
    platform_domain: "the default address is not removable"
  }

  json_api do
    type("instance_hostname")

    routes do
      # instances:write — the member mint; ownership is the authorized
      # instance read inside the operation.
      post(:mint_member,
        route: "/instances/:instance_id/hostnames",
        default_fields: @hostname_fields
      )

      # instances:read — the instance's addresses.
      index(:list_for_instance,
        route: "/instances/:instance_id/hostnames",
        default_fields: @hostname_fields
      )

      # instances:write — the member remove; ownership is the authorized
      # hostname + instance reads inside the operation.
      route(:delete, "instance-hostnames/:id", :remove_member)
    end
  end

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

  # The audit trail (#645, ADR-0048): the plan's one complete config
  # posture — the mixin line is mandatory (it carries the read policy,
  # the indexes, the actor label). version_extensions attaches the
  # Policy authorizer that policy rides on. Rationale lives in the
  # ADR, not here.
  paper_trail do
    primary_key_type(:uuid_v7)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    store_action_inputs?(true)
    sensitive_attributes(:redact)
    ignore_attributes([:created_at, :updated_at])
    reference_source?(false)
    create_version_on_destroy?(true)
    operation_id_field(:operation_id)
    mixin({FluxVale.PaperTrail.VersionMixin, :version_resource, []})
    version_extensions(authorizers: [Ash.Policy.Authorizer])

    belongs_to_actor(:user, FluxVale.Identity.User,
      domain: FluxVale.Identity,
      on_delete: :nilify
    )
  end

  policies do
    # The blanket authority (#644, ADR-0047): platform admins see and do
    # everything — but never through the machine API (the second
    # condition), so PAT callers fall through to the policies below
    # with today's semantics.
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description("Platform admins see and do everything (#644)")
      authorize_if(always())
    end

    # A hostname is visible iff its instance is (the instance's own read
    # policy scopes to org members).
    policy action_type(:read) do
      description("Hostname reads ride the instance's policy")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    # Minted and deleted by the system paths (instance create, the
    # operation seam's row writes); members never write a hostname
    # directly. The member verbs below are generic actions whose
    # ownership fence is the authorized read inside the operation.
    policy action_type([:create, :destroy]) do
      description("System-only: MintDefaultHostname owns the writes (authorize?: false)")
      forbid_if(always())
    end

    # The member verbs (the AccessDomain.remove_via_api posture): the
    # actor's hand is checked by the authorized instance/domain reads
    # inside the operation; a non-member's row is a not-found there.
    policy action([:mint_member, :remove_member]) do
      description("Member hostname verbs — ownership is enforced inside the operation")
      authorize_if(actor_present())
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

    read :list_for_instance do
      description("The instance's addresses, oldest first (the page card and the API route).")
      argument(:instance_id, :uuid, allow_nil?: false)
      filter(expr(instance_id == ^arg(:instance_id)))
      prepare(build(sort: [created_at: :asc, id: :asc]))
    end

    # The member mint — the operation owns the ownership fence, the
    # domain/state guards, the edge re-apply, and the render hook.
    action :mint_member, :struct do
      description("""
      Adds a custom address under a verified custom domain owned by the
      instance's organization. Refuses a foreign domain, a platform
      domain, and an unverified one.
      """)

      argument(:instance_id, :uuid, allow_nil?: false, public?: true)
      argument(:access_domain_id, :uuid, allow_nil?: false, public?: true)
      argument(:label, :string, allow_nil?: false, public?: true)
      constraints(instance_of: __MODULE__)

      run(fn input, %{actor: actor, authorize?: authorize?, source_context: context} ->
        case FluxVale.Infrastructure.mint_custom_hostname(
               input.arguments.instance_id,
               input.arguments.access_domain_id,
               input.arguments.label,
               actor: actor,
               authorize?: authorize?,
               context: context
             ) do
          {:ok, hostname} -> {:ok, hostname}
          {:error, reason} -> {:error, mint_error(reason)}
        end
      end)
    end

    # The member remove — the operation deletes the row's edge routes,
    # then the row, then re-renders the resolver view.
    action :remove_member, :struct do
      description("Removes one of the instance's custom addresses.")

      argument(:id, :uuid, allow_nil?: false, public?: true)
      constraints(instance_of: __MODULE__)

      run(fn input, %{actor: actor, authorize?: authorize?, source_context: context} ->
        case FluxVale.Infrastructure.remove_custom_hostname(input.arguments.id,
               actor: actor,
               authorize?: authorize?,
               context: context
             ) do
          {:ok, hostname} -> {:ok, hostname}
          {:error, reason} -> {:error, remove_error(reason)}
        end
      end)
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:mint)
    define(:destroy)
    define(:list_for_instance, args: [:instance_id])
    define(:mint_member, args: [:instance_id, :access_domain_id, :label])
    define(:remove_member, args: [:id])
  end

  identities do
    # One label per domain — the traffic-hijack boundary (see moduledoc).
    identity(:unique_label_per_domain, [:access_domain_id, :label])
  end

  # The mint's guard atoms get the owner's words; anything else (a
  # duplicate label, a K8s failure, Forbidden) passes through untouched.
  defp mint_error(reason) when is_map_key(@mint_refusals, reason) do
    message = Map.fetch!(@mint_refusals, reason)

    InvalidArgument.exception(message: message)
  end

  defp mint_error(reason), do: reason

  defp remove_error(reason) when is_map_key(@remove_refusals, reason) do
    message = Map.fetch!(@remove_refusals, reason)

    InvalidArgument.exception(message: message)
  end

  defp remove_error(reason), do: reason
end

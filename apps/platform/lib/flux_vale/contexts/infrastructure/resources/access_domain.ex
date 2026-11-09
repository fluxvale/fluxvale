defmodule FluxVale.Infrastructure.AccessDomain do
  @moduledoc """
  A domain an org serves its private instances under (ADR-0040):

  - `:platform` — FluxVale's own `instances_base_domain`, one row per
    org, system-minted (`Operations`-free: the instance create path's
    `MintDefaultHostname` find-or-creates it), born `:verified` — the
    fleet wildcard already covers it, so there is nothing to issue and
    nothing to bill.
  - `:custom` — the owner's own domain (`apps.customer.com`). Registered
    as `:pending` with a wildcard Certificate (`*.apps.customer.com`)
    issued DNS-01 through the delegated `_acme-challenge` record; the
    Ready condition is the verification (`verify-by-issuance`) and the
    only promoter to `:verified` is `Operations.VerifyAccessDomains` —
    the gateway-observer stance: the row never claims a posture the
    cluster has not reported.

    Wildcard-of-subzone is the only self-serve shape (no per-hostname
    certs), and custom domains are private-first: nothing here models
    public serving.

  `cert_secret_ref` names the Secret cert-manager writes the issued
  wildcard into — written only by the verify pass, from the Certificate
  it observed. Internal: a technical ref, not a customer surface (the
  gateway's `credential_secret_ref` stance).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Error.Changes.InvalidArgument
  alias FluxVale.Infrastructure.AccessDomain.EnsureRegistrable
  alias FluxVale.Infrastructure.InstanceHostname

  # #482 P2 (ADR-0019 §1): the custom-domain family's wire contract —
  # the provider's register/list/inspect/resume/remove. Public
  # attributes only; cert_secret_ref is an internal k8s object name,
  # not API surface — off every list. organization_id is the org
  # reference the provider wants on the wire.
  @domain_fields [:id, :domain, :kind, :state, :organization_id]

  json_api do
    type("access_domain")

    routes do
      # gateways:read — the org's domains (the provider's list). A
      # foreign org's list answers 200 [] (index semantics): a mistyped
      # org id reads as "no domains", so source organization ids from
      # the org list (GET /organizations), never hand-typed.
      index(:list_for_org,
        route: "/organizations/:organization_id/access-domains",
        default_fields: @domain_fields
      )

      # gateways:read
      get(:get_by_id, route: "/access-domains/:id", default_fields: @domain_fields)

      # gateways:write — the register action carries the full
      # registration: the row AND the wildcard Certificate mint, one
      # transaction (MintCertificate). Gates ride the policy:
      # membership AND a paid-once wallet AND a funded wallet (ADR-0040
      # Am. 2). The org rides the organization_id argument
      # (member-fenced, #408); no argument keeps the personal-org
      # default.
      post(:register, route: "/access-domains", default_fields: @domain_fields)

      # gateways:write — resume's gates are lighter than register's:
      # membership AND a funded wallet (no paid-once gate — resuming is
      # not unlocking).
      patch(:resume, route: "/access-domains/:id/resume", default_fields: @domain_fields)

      # gateways:write — the wire's remove runs the FULL operation
      # (remove_via_api below), in its safety order: tailnet unclaim,
      # THEN the row destroy, the Corefile re-render, and the
      # Certificate safe-delete — live TLS state must never be deleted
      # while the row still stands, and a destroyed row is the only
      # point from which the cert delete is safe. Routing the raw
      # :remove destroy instead would leak a Certificate per provider
      # retry — no row left to re-derive the unclaim from.
      route(:delete, "access-domains/:id", :remove_via_api)
    end
  end

  postgres do
    table("access_domains")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    custom_indexes do
      # Platform-wide :custom ownership backstop (see the identities'
      # comment): two orgs must never hold Certificates for the same
      # dnsName. Partial — per-org :platform rows are same-domain by
      # design; only :custom rows are globally unique.
      index([:domain],
        unique: true,
        name: "access_domains_custom_domain_unique",
        where: "kind = 'custom'"
      )
    end

    # Restrict, not cascade — the AccessGateway stance: the org delete
    # flow (when it lands) must go through removals that also delete the
    # cluster Certificates, and the row must exist while they do.
    references do
      reference(:organization, on_delete: :restrict)
    end
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

    policy action_type(:read) do
      description("Members read their org's domains")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    # Registering is a member's act on an org they belong to; the org is
    # the register action's context (the named org, else the actor's own,
    # #408). This fence denies a non-member's named org, reading the
    # organization_id the tenancy change set before policies run — the
    # create-template posture ActorIsOrganizationMember exists for.
    #
    # The entitlement gate (ADR-0040 Amendment 2): custom domains are
    # free to USE but not free to UNLOCK. The same pair the gateway's
    # create carries — a real $1+ top-up ever (the welcome credit does
    # not qualify) and a positive balance right now — so an account that
    # has never paid, or has drained, cannot register a domain. Policy
    # land, so the API cannot walk around it.
    policy action(:register) do
      description(
        "Members register their org's own domains — membership AND a paid-once wallet AND a funded wallet"
      )

      forbid_unless(FluxVale.Checks.ActorIsOrganizationMember)
      forbid_unless(FluxVale.Checks.ActorOrgHasPaid)
      forbid_unless(FluxVale.Checks.ActorOrgWalletFunded)
      authorize_if(FluxVale.Checks.ActorIsOrganizationMember)
    end

    # The platform row is system-minted (instance create), never
    # member-registered — hence its own action and a deny-all policy.
    policy action(:mint_platform) do
      description("System-only: the instance-create path's platform row (authorize?: false)")
      forbid_if(always())
    end

    # The state funnels are the observer's writes — the platform's read
    # of the cluster, never the owner's opinion of it.
    policy action([:mark_verified, :mark_failed, :mark_needs_attention, :mark_suspended]) do
      description("System-only: observed issuance state (authorize?: false)")
      forbid_if(always())
    end

    # Resuming a suspended domain: membership AND a funded wallet —
    # NOT the paid-once gate register carries (resuming is not
    # unlocking).
    policy action(:resume) do
      description("Members resume their org's own domain — membership AND a funded wallet")
      forbid_unless(relates_to_actor_via([:organization, :members]))
      authorize_if(FluxVale.Checks.ActorOrgWalletFunded)
    end

    policy action(:remove) do
      description("Members remove their org's custom domains")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    # The wire's remove verb (#482 P2): the actor fence is the
    # authorized get_by_id inside the action (the Instance :delete
    # stance) — a non-member's row is 404 before any cluster call.
    policy action(:remove_via_api) do
      description(
        "The API remove: ownership is enforced by the authorized get_by_id inside the action"
      )

      authorize_if(actor_present())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    # Dot-joined DNS name ("apps.customer.com"), stored trimmed and
    # downcased (the :register change normalizes). The shape mirrors
    # ingress.ex's @dns_label posture: dot-separated DNS labels, alnum +
    # inner hyphens, 1-63 chars each. Rejects backticks, backslashes,
    # spaces — anything that would make a dead or injectable
    # cert-manager/Traefik object name. \z (not $): a trailing newline
    # must not slip through ($ matches before a final \n in PCRE).
    attribute :domain, :string do
      allow_nil?(false)
      public?(true)

      constraints(
        match:
          ~r/^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+\z/,
        # 251 = RFC 253's 253-octet printable name minus the "*." our
        # wildcard dnsName ("*.#{domain}") adds — the row stores the
        # bare domain, the Certificate carries the star.
        max_length: 251
      )
    end

    attribute :kind, FluxVale.Infrastructure.Types.AccessDomainKind do
      allow_nil?(false)
      public?(true)
    end

    attribute :state, FluxVale.Infrastructure.Types.AccessDomainState do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    # The Secret cert-manager writes the issued wildcard into — set only
    # by the verify pass, read from the observed Certificate's
    # spec.secretName (never guessed from config).
    attribute :cert_secret_ref, :string do
      public?(false)
    end

    # When the org registered (or the platform row was minted). Also the
    # issuance-deadline anchor: the verify pass fails a :pending row
    # whose wait outlived `issuance_deadline_hours`. A create timestamp
    # by design — registration IS creation for this row; the generic
    # created_at/updated_at stay the repo's audit pair.
    create_timestamp(:registered_at)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :organization, FluxVale.Accounts.Organization do
      allow_nil?(false)
      public?(true)
    end

    has_many :instance_hostnames, InstanceHostname do
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :register do
      description("""
      Registers the org's own domain as :pending and :custom (ADR-0040).
      The row claims nothing yet: verification is issuance, and only the
      observer pass — after reading the Certificate's Ready condition —
      promotes to :verified. Platform rows are system-minted
      (:mint_platform), never member-registered, hence the forced kind.
      """)

      accept([:domain])

      # The register action's org context (#408): naming an org registers
      # into it (member-fenced by the register policy); leaving it nil
      # keeps the actor's own org as the default.
      argument(:organization_id, :uuid, allow_nil?: true)

      change(FluxVale.Infrastructure.AccessDomain.SetOrganizationFromActor)

      # The registration boundaries (platform domain, platform-wide
      # custom uniqueness) — checked here so no caller can bypass them.
      change(EnsureRegistrable)

      # The cluster leg (ADR-0040 S1): the wildcard Certificate lands
      # inside the create's transaction — after_action, so a failure
      # rolls the row back WITH it. Every register entry point (panel
      # operation, API route) mints through this one change.
      change(FluxVale.Infrastructure.AccessDomain.MintCertificate)

      # Normalize before validation: trimmed + downcased, so
      # "Apps.Customer.COM." -style input lands canonical and the
      # unique (organization_id, domain) identity can't be forked by
      # case. (Validation runs after changes — the v1 pattern.)
      change(fn changeset, _context ->
        domain = Ash.Changeset.get_attribute(changeset, :domain)

        if is_binary(domain) do
          trimmed = String.trim(domain)
          canonical = String.downcase(trimmed)

          Ash.Changeset.force_change_attribute(changeset, :domain, canonical)
        else
          changeset
        end
      end)

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :kind, :custom)
      end)

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :state, :pending)
      end)
    end

    create :mint_platform do
      description("""
      System-only: mints the org's :platform row (kind/state forced,
      domain accepted) — born :verified because the fleet wildcard
      already covers the platform domain; there is nothing to issue.
      Find-or-create discipline lives in the caller
      (Instance.MintDefaultHostname); the unique
      (organization_id, domain) identity is the race backstop.
      """)

      accept([:domain, :organization_id])

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :kind, :platform)
      end)

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :state, :verified)
      end)
    end

    read :get_by_id do
      description("Get a domain by id")
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    # The system-wide list the observer pass walks (the gateway's
    # list_all stance: unbounded + actorless, system seam only).
    read :list_all do
      description("Every access domain (the verify pass's input)")
    end

    # #482 P2: the provider's per-org list — the route path's
    # organization_id feeds the filter, and the read policy's membership
    # fence keeps another org's rows invisible.
    read :list_for_org do
      description("The org's access domains (the provider's list)")
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end

    # The state funnels — one per transition, system-only (policies
    # above), called authorize?: false by the observer/remove operations.

    update :mark_verified do
      description("System-only: the Certificate observed Ready=True; record its Secret ref.")
      accept([:cert_secret_ref])
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :state, :verified)
      end)
    end

    update :mark_failed do
      description("""
      System-only: the issuance window lapsed without Ready=True. The
      owner removes the failed row, THEN re-registers — the platform-
      wide custom-domain uniqueness refuses a same-name re-register
      while the row stands.
      """)

      accept([])
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :state, :failed)
      end)
    end

    update :mark_needs_attention do
      description("System-only: a verified Certificate's Ready went False.")
      accept([])
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :state, :needs_attention)
      end)
    end

    update :mark_suspended do
      description("""
      System-only: pauses a custom domain. The domain's edge routes and
      its tailnet claim go dark with it (see Suspend). Domains no
      longer bill, so no ladder arm calls this any more. The action
      stays for the legacy rows a paid owner can still resume.
      """)

      accept([])
      require_atomic?(false)

      change(FluxVale.Infrastructure.AccessDomain.Suspend)
    end

    update :resume do
      description("""
      The owner's funded resume of a suspended domain — the row back to
      :verified, the tailnet claim and the domain's access arms
      re-minted (see Resume).
      """)

      require_atomic?(false)
      accept([])

      change(FluxVale.Infrastructure.AccessDomain.Resume)
    end

    destroy :remove do
      description("""
      Removes a domain row — :custom only. The platform row is load-
      bearing (every instance's default hostname points at it) and is
      never removable; the guard below is the resource-level backstop to
      Operations.RemoveAccessDomain's own kind check.
      """)

      require_atomic?(false)

      change(fn changeset, _context ->
        if changeset.data.kind == :platform do
          Ash.Changeset.add_error(
            changeset,
            field: :kind,
            message: "the platform domain is not removable"
          )
        else
          changeset
        end
      end)
    end

    # #482 P2: the wire's remove verb — the gateway family's generic-
    # action shape. The authorized get_by_id is the ownership fence
    # (a non-member's row is 404 before any cluster call), then the
    # operation through the domain seam owns the rest: the platform
    # and hostnames guards, the tailnet unclaim, the row, the Corefile
    # re-render, the Certificate safe-delete.
    action :remove_via_api, :struct do
      description("""
      Removes a custom domain — the full removal operation. Refuses the
      platform kind and a domain that still serves hostnames.
      """)

      argument(:id, :uuid, allow_nil?: false, public?: true)
      constraints(instance_of: __MODULE__)

      run(fn input, %{actor: actor, authorize?: authorize?, source_context: context} ->
        case get_by_id(input.arguments.id,
               actor: actor,
               authorize?: authorize?,
               context: context
             ) do
          {:ok, domain} ->
            case FluxVale.Infrastructure.remove_access_domain(domain,
                   actor: actor,
                   authorize?: authorize?
                 ) do
              :ok -> {:ok, domain}
              {:error, reason} -> {:error, remove_error(reason)}
            end

          {:error, _reason} = error ->
            error
        end
      end)
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:register)
    define(:mint_platform)
    define(:get_by_id, args: [:id])
    define(:list_all)
    define(:list_for_org, args: [:organization_id])
    define(:mark_verified)
    define(:mark_failed)
    define(:mark_needs_attention)
    define(:mark_suspended)
    define(:resume)
    define(:remove)
    define(:remove_via_api, args: [:id])
  end

  identities do
    # Per-org scoping only: one org holds one row per domain (and an
    # org's platform row and custom row can't share a name either).
    # Platform-WIDE custom-domain ownership is not expressible as a
    # per-org identity — it is the register validation
    # (EnsureRegistrable) plus the `access_domains_custom_domain_unique`
    # partial index: a race between two orgs loses on the constraint,
    # loudly.
    identity(:unique_org_domain, [:organization_id, :domain])
  end

  # The cert-manager Certificate (and the Secret its wildcard lands in)
  # for this row — the ONE derivation every operation shares:
  # RegisterAccessDomain mints it, VerifyAccessDomains reads it,
  # RemoveAccessDomain deletes it. They must agree or the system breaks,
  # so the derivation lives on the row itself (the provider's ownership
  # of gateway object names, moved to where the row is).
  #
  # The suffix comes from the RANDOM TAIL of the id — the tailscale
  # provider's short-id discipline: a uuid v7's leading hex is a
  # millisecond timestamp, identical for every domain registered in the
  # same ~65s window, so using it would collide two orgs' object names.
  @doc false
  @spec certificate_name(t()) :: String.t()
  def certificate_name(%__MODULE__{id: id}) do
    short_id =
      id
      |> to_string()
      |> String.replace("-", "")
      |> String.slice(-10, 10)

    "access-domain-#{short_id}"
  end

  # The Certificate spec register applies and the verify pass RE-applies
  # (the reconcile limb) — one owner for the whole identity (wildcard
  # dnsName, Secret name, issuer), so a reconcile can never converge on
  # a differently-shaped object than registration made. The issuer is
  # the DNS-01 ClusterIssuer named from config (the fleet side owns the
  # object; see config.exs).
  @doc false
  @spec certificate_spec(t()) :: %{
          domain: String.t(),
          secret_name: String.t(),
          issuer: String.t()
        }
  def certificate_spec(%__MODULE__{} = domain) do
    config = Application.fetch_env!(:flux_vale, :access_domains)

    %{
      domain: "*.#{domain.domain}",
      secret_name: certificate_name(domain),
      issuer: Keyword.fetch!(config, :issuer)
    }
  end

  # --- the API remove verb's helpers (#482 P2) -----------------------

  # The operation's guard atoms carry no message of their own; give
  # them the owner's plain words (the Instance backup verbs' stance).
  # Anything else (an unclaim failure, a K8s error, Forbidden) passes
  # through untouched — the honest 5xx/403 shape.
  @remove_refusals %{
    platform_kind: "the platform domain is not removable",
    hostnames_present: "this domain still serves instance hostnames. Remove them first"
  }

  defp remove_error(reason) when is_map_key(@remove_refusals, reason) do
    message = Map.fetch!(@remove_refusals, reason)

    InvalidArgument.exception(message: message)
  end

  defp remove_error(reason), do: reason
end

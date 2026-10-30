defmodule FluxVale.Infrastructure.AccessDomain do
  @moduledoc """
  A domain an org serves its private instances under (ADR-0040):

  - `:platform` — FluxVale's own `instances_base_domain`, one row per
    org, system-minted (`Operations`-free: the instance create path's
    `MintDefaultHostname` find-or-creates it), born `:verified` — the
    fleet wildcard already covers it, so there is nothing to issue and
    (S6) nothing to bill.
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
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Infrastructure.InstanceHostname

  postgres do
    table("access_domains")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # Restrict, not cascade — the AccessGateway stance: the org delete
    # flow (when it lands) must go through removals that also delete the
    # cluster Certificates, and the row must exist while they do.
    references do
      reference(:organization, on_delete: :restrict)
    end
  end

  policies do
    policy action_type(:read) do
      description("Members read their org's domains")
      authorize_if(relates_to_actor_via([:organization, :members]))
    end

    # Registering is the owner's act on their own org; the org is forced
    # from the actor (the Instance create contract), so a member can
    # never mint a row into another org.
    policy action(:register) do
      description("Members register their org's own domains")
      authorize_if(relates_to_actor_via([:organization, :members]))
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

    policy action(:remove) do
      description("Members remove their org's custom domains")
      authorize_if(relates_to_actor_via([:organization, :members]))
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
          ~r/^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+\z/
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

      change({FluxVale.Infrastructure.Instance.SetOrganizationFromActor, []})

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
      owner re-registers (a fresh row and Certificate).
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
      System-only: the S6 billing ladder's suspension (a lapsed custom
      domain). No writer yet — S6 owns it; the funnel exists so the
      ladder lands through the same one-funnel-per-transition discipline.
      """)

      accept([])
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :state, :suspended)
      end)
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
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:register)
    define(:mint_platform)
    define(:get_by_id, args: [:id])
    define(:list_all)
    define(:mark_verified)
    define(:mark_failed)
    define(:mark_needs_attention)
    define(:mark_suspended)
    define(:remove)
  end

  identities do
    # One org registers a given domain once (and the platform row and a
    # custom row can never collide on the same name either).
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
end

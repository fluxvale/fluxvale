defmodule FluxVale.Identity.User do
  @moduledoc """
  The platform user — email-identified, passwordless (ADR-0003).

  Accounts are JIT-provisioned on first successful code verification (#21 —
  the strategy creates users through the AshAuthenticationInteraction
  bypass). `platform_role` is the global staff axis; see
  `FluxVale.Identity.Types.PlatformRole` for why org roles never land here.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource FluxVale.Identity.Token
      signing_secret FluxVale.Identity.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true

      # Sessions are absolute-TTL: ash_authentication has no refresh tokens,
      # so `exp` is baked at mint and use never extends it (ADR-0003; 60d
      # mid-band settled on #20). Revocation is the separate, instant
      # mechanism — every auth checks a live token-store row (both options
      # above). Revisit trigger: daily users annoyed by the periodic email
      # round-trip — then a re-mint-on-activity plug, not a longer TTL.
      token_lifetime {60, :days}
    end
  end

  policies do
    bypass(AshAuthentication.Checks.AshAuthenticationInteraction) do
      description "AshAuthentication's own interactions (strategy sign-in, token storage)"
      authorize_if(always())
    end

    policy FluxVale.Policies.PlatformAdmin do
      description "Platform admins manage users"
      authorize_if(always())
    end
  end

  postgres do
    table "users"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job. ash_postgres
    # would emit uuid_generate_v7(), which no stock Postgres provides (PG18's
    # native one is uuidv7()); a v4 gen_random_uuid() backstop would
    # silently mint mismatched ids. A non-Ash insert omitting id fails loudly
    # instead (NOT NULL) — the intended guardrail.
    migration_defaults id: "nil"
  end

  attributes do
    # ADR-0032: UUIDv7 — time-ordered for index locality + keyset cursors;
    # ordering is approximate, never a contract. NB: the explicit default is
    # required — uuid_primary_key's built-in default still generates v4.
    uuid_primary_key(:id, type: :uuid_v7, default: &Ash.UUIDv7.generate/0)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    # public? from day one — the API surface is deliberate design, not an
    # afterthought of the LiveView UI (ADR-0019 §1; /api/me arrives in #24)
    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    attribute :platform_role, FluxVale.Identity.Types.PlatformRole do
      allow_nil?(false)
      default(:user)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      # Serves admins and the bootstrap seed (which runs authorize?: false —
      # there is no actor to authorize before the first admin exists).
      # Anonymous JIT registration is NOT this action; it arrives with the
      # email-code strategy (#21) under the interaction bypass above.
      primary? true
      accept([:email, :platform_role])
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument(:subject, :string, allow_nil?: false)
      get?(true)
      prepare(AshAuthentication.Preparations.FilterBySubject)
    end

    read :get_by_email do
      description "Get a user by email"
      argument(:email, :ci_string, allow_nil?: false)
      get?(true)
      filter(expr(email == ^arg(:email)))
    end
  end

  code_interface do
    domain FluxVale.Identity

    define(:create, args: [:email])
    define(:get_by_email, args: [:email])
  end

  identities do
    identity(:unique_email, [:email])
  end
end

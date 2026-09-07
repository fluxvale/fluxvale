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

  require Logger

  # PAT lifetime: 1 year (v1's value, ported — #23). Absolute, like
  # sessions — `exp` bounds the worst case; revocation is the instant
  # mechanism (a live token-store row check on every authentication).
  @pat_lifetime_seconds 365 * 24 * 60 * 60

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

    policy FluxVale.Checks.ActorIsPlatformAdmin do
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

    # PATs (#23): v1's shape ported — a generic action minting a 1-yr JWT
    # through `token_for_user/4`, which also stores it in the revocable
    # token store (`store_all_tokens?`), so revocation severs a PAT as
    # instantly as a session. Headless clients present it as
    # `Authorization: Bearer <token>`; the mint surface in M2 is the code
    # interface (IEx) — a user-facing mint arrives with a consumer.
    action :mint_pat, :string do
      description "Mints a long-lived PAT for the user with the given email."

      argument(:email, :ci_string, allow_nil?: false)

      # The action itself sits behind the platform-admin policy (generic
      # actions authorize by default). v1 bypassed authorization on this
      # lookup; v2 runs it under the calling actor instead (settled on
      # #23) — an admin is authorized to read users anyway, and the
      # operator path stays `authorize?: false` (same as `create`).
      run(fn input, context ->
        with {:ok, user} <-
               get_by_email(input.arguments.email,
                 actor: context.actor,
                 authorize?: context.authorize?
               ) do
          exp = System.system_time(:second) + @pat_lifetime_seconds

          case AshAuthentication.Jwt.token_for_user(user, %{"exp" => exp}) do
            {:ok, token, _claims} ->
              # Audit the mint, never the token value (v1 posture).
              Logger.info("PAT minted for user #{input.arguments.email}")
              {:ok, token}

            :error ->
              {:error, Ash.Error.to_error_class("failed to generate token")}
          end
        end
      end)
    end
  end

  code_interface do
    domain FluxVale.Identity

    define(:create, args: [:email])
    define(:get_by_email, args: [:email])
    define(:mint_pat, args: [:email])
  end

  identities do
    identity(:unique_email, [:email])
  end
end

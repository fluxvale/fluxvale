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
    extensions: [AshAuthentication, AshJsonApi.Resource]

  alias FluxVale.Identity.User.DeriveUsername
  alias FluxVale.Identity.User.MirrorSignupEmail
  alias FluxVale.Identity.User.ProvisionPersonalOrg

  require Logger

  # PAT lifetime: 1 year (v1's value, ported — #23). Absolute, like
  # sessions — `exp` bounds the worst case; revocation is the instant
  # mechanism (a live token-store row check on every authentication).
  @pat_lifetime_seconds 365 * 24 * 60 * 60

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change?(true)
      end
    end

    tokens do
      enabled?(true)
      token_resource(FluxVale.Identity.Token)
      signing_secret(FluxVale.Identity.Secrets)
      store_all_tokens?(true)
      require_token_presence_for_authentication?(true)

      # Sessions are absolute-TTL: ash_authentication has no refresh tokens,
      # so `exp` is baked at mint and use never extends it (ADR-0003; 60d
      # mid-band settled on #20). Revocation is the separate, instant
      # mechanism — every auth checks a live token-store row (both options
      # above). Revisit trigger: daily users annoyed by the periodic email
      # round-trip — then a re-mint-on-activity plug, not a longer TTL.
      token_lifetime({60, :days})
    end
  end

  policies do
    bypass(AshAuthentication.Checks.AshAuthenticationInteraction) do
      description("AshAuthentication's own interactions (strategy sign-in, token storage)")
      authorize_if(always())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("Platform admins manage users")
      authorize_if(always())
    end

    # always() is honest here: the action's actor filter already constrains
    # the result to the caller, so "any authenticated actor may run :me"
    # cannot leak another record (nil actor never reaches policy — the
    # filter errors ReadActionRequiresActor first).
    policy action(:me) do
      description("Any authenticated user reads their own record")
      authorize_if(always())
    end
  end

  json_api do
    type("user")

    routes do
      # GET /api/v1/me — the current actor's record, no id (#24). The only
      # public User surface: deliberately no collection routes (listing
      # users is not a machine API — ADR-0019 §1).
      get(:me, route: "/me")
    end
  end

  postgres do
    table("users")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job. ash_postgres
    # would emit uuid_generate_v7(), which no stock Postgres provides (PG18's
    # native one is uuidv7()); a v4 gen_random_uuid() backstop would
    # silently mint mismatched ids. A non-Ash insert omitting id fails loudly
    # instead (NOT NULL) — the intended guardrail.
    migration_defaults(id: "nil")
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
    #
    # FROZEN mirror (#285 T3): identity resolution reads `user_emails`
    # now; this column stays written on create only so old pods keep
    # resolving new users during rolling deploys. `set_primary` does NOT
    # rewrite it — the follow-up contract release drops the column.
    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    # GitHub-style handle (#285 T2): derived from the email at signup
    # (DeriveUsername — the only writer in this slice). Nullable until a
    # later contract migration flips NOT NULL: existing rows and the
    # rolling-deploy window need the slack. Its own namespace among
    # users — organization slugs are never consulted.
    attribute :username, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :platform_role, FluxVale.Identity.Types.PlatformRole do
      allow_nil?(false)
      default(:user)
      public?(true)
    end
  end

  relationships do
    # The user's email rows (#285 T3) — the table-backed identity the
    # sign-in lookup rides. Private: no serialization surface.
    has_many :emails, FluxVale.Identity.UserEmail do
      destination_attribute(:user_id)
      public?(false)
    end
  end

  actions do
    defaults([:read])

    create :create do
      # The one registration path is JIT signup (#21): a valid email code
      # proves inbox ownership and provisions through this action (under
      # the interaction bypass above). Serves admins and the bootstrap
      # seed too (which runs authorize?: false — there is no actor to
      # authorize before the first admin exists).
      primary?(true)
      accept([:email, :platform_role])

      # Username derivation (#285 T2) — the only writer (no input
      # surface, no format validation until the rename UI), always
      # producing a 2–39 [a-z0-9-] value; residual failure arms (probe
      # read failure, lost race) fail loudly, like provisioning's.
      # Listed BEFORE ProvisionPersonalOrg: provisioning must see the
      # username — it names the org after it (#285 T7).
      change(DeriveUsername)

      # Every registration path gets an org (#119) — JIT signup, seeds,
      # admin-created users. Runs in the create transaction; see the
      # change module.
      change(ProvisionPersonalOrg)

      # The mirror row (#285 T3 §5) — same transaction: the account is
      # born with its verified primary user_emails row, the same end
      # state the T1 backfill gave every pre-existing user.
      change(MirrorSignupEmail)
    end

    # /api/v1/me (#24): the actor-template filter is the whole trick — the
    # query can only ever return the caller, and a nil actor fails loudly
    # (ReadActionRequiresActor) before policy runs. Same templating shape
    # as get_by_email's ^arg(:email).
    read :me do
      description("The current actor's own record")
      filter(expr(id == ^actor(:id)))
    end

    read :get_by_subject do
      description("Get a user by the subject claim in a JWT")
      argument(:subject, :string, allow_nil?: false)
      get?(true)
      prepare(AshAuthentication.Preparations.FilterBySubject)
    end

    # Table-backed (#285 T3): the address resolves through `user_emails` —
    # a VERIFIED row's user. A pending claim never resolves, and an
    # unknown address is not found, as before. Name, argument, and code
    # interface unchanged: callers (seeds, PAT mint) keep their shape.
    # unique_address guarantees at most one row per address, so the get?
    # contract holds. `exists` DOES apply UserEmail's related-resource
    # policies, fail-closed: a caller they don't authorize reads
    # not-found, not forbidden. The AshAuthentication interaction bypass
    # is what carries the auth flows; a future owner-actor caller would
    # read not-found for their own address unless UserEmail's policies
    # allow them.
    read :get_by_email do
      description("Get a user by one of their verified email addresses")
      argument(:email, :ci_string, allow_nil?: false)
      get?(true)
      filter(expr(exists(emails, address == ^arg(:email) and not is_nil(verified_at))))
    end

    # Same policy posture as get_by_email (#285 T2): only the
    # AshAuthentication interaction bypass and platform admins get past
    # the policies — no public listing surface. DeriveUsername's probe
    # is a system path and calls it authorize?: false.
    read :get_by_username do
      description("Get a user by username")
      argument(:username, :string, allow_nil?: false)
      get?(true)
      filter(expr(username == ^arg(:username)))
    end

    # PATs (#23): v1's shape ported — a generic action minting a 1-yr JWT
    # through `token_for_user/4`, which also stores it in the revocable
    # token store (`store_all_tokens?`), so revocation severs a PAT as
    # instantly as a session. Headless clients present it as
    # `Authorization: Bearer <token>`; the mint surface in M2 is the code
    # interface (IEx) — a user-facing mint arrives with a consumer.
    action :mint_pat, :string do
      description("Mints a long-lived PAT for the user with the given email.")

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

            # coveralls-ignore-start - Jwt signing failure (secret missing /
            # malformed) — prod-config error, not exercisable in test env
            :error ->
              {:error, Ash.Error.to_error_class("failed to generate token")}
              # coveralls-ignore-stop
          end
        end
      end)
    end
  end

  code_interface do
    domain(FluxVale.Identity)

    define(:create, args: [:email])
    define(:get_by_email, args: [:email])
    define(:get_by_username, args: [:username])
    define(:mint_pat, args: [:email])
  end

  identities do
    identity(:unique_email, [:email])

    # Usernames are unique among users (#285 T2) — a separate namespace
    # from organization slugs, deliberately.
    identity(:unique_username, [:username])
  end
end

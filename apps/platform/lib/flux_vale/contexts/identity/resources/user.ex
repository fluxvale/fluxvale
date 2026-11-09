defmodule FluxVale.Identity.User do
  @moduledoc """
  The platform user — email-identified, passwordless (ADR-0003).

  Accounts are JIT-provisioned on first successful code verification (#21 —
  the strategy creates users through the AshAuthenticationInteraction
  bypass). `platform_role` is the global staff axis; see
  `FluxVale.Identity.Types.PlatformRole` for why org roles never land here.

  Addresses live ONLY in `user_emails` (#285 T3, #287): the signup
  address is an `:email` argument on `:create`/`:invite` (public by
  necessity — see the action comments), never a column — the legacy
  `users.email` mirror is dropped, and with it every heal path that
  read it (the pre-launch wipe doctrine absorbed its stragglers;
  ADR-0013 Am. 1).

  Invited accounts (#502, re-homed #287) are pre-provisioned through
  :invite and INERT until acceptance: no org, and their address sits as
  a PENDING `user_emails` row — the invitation's reservation (see
  InvitedEmailRow for the window semantics). The invite stamps
  (`invited_at`, `invite_accepted_at`, `invite_withdrawn_at`,
  `invite_expires_at`) describe the outstanding invitation, and the raw
  accept token exists only in the emailed link (the row stores its
  SHA-256 hash alone, `invite_token_hash`). Acceptance (:accept_invite)
  runs the same bootstrap a first sign-in runs — minus username
  derivation, which the invite already did — and stamps
  `invite_accepted_at`. Every normal account carries nil in all five
  columns and answers :none from `invite_state`.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication, AshJsonApi.Resource]

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity.User.AcceptInvitedEmailRow
  alias FluxVale.Identity.User.DeriveUsername
  alias FluxVale.Identity.User.InvitedEmailRow
  alias FluxVale.Identity.User.ProvisionPersonalOrg
  alias FluxVale.Identity.User.SignupEmailRow
  alias FluxVale.Identity.User.ValidUsername

  # The invitation window (#502) — the mail copy reads invite_ttl_days/0
  # so the sentence and the row can never drift (the MembershipInvite
  # @ttl_days posture).
  @invite_ttl_days 7

  authentication do
    add_ons do
      # Dormant: log_out_everywhere fires only on password-strategy
      # changes and this app is passwordless. Revisit the day a password
      # strategy lands.
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

    # The blanket authority (#644, ADR-0047): platform admins see and do
    # everything — but never through the machine API (the second
    # condition), so PAT callers fall through to the policies below
    # with today's semantics. Replaces the former blanket admin policy
    # (the bypass subsumes it for every non-PAT caller).
    bypass [FluxVale.Checks.ActorIsPlatformAdmin, FluxVale.Checks.CallOutsideMachineApi] do
      description("Platform admins see and do everything (#644)")
      authorize_if(always())
    end

    # No policy names the invite actions (#502): the admin bypass above
    # admits platform admins for :invite/:reinvite/:withdraw_invite and
    # the token-seam reads/writes (:get_by_invite_token_hash,
    # :accept_invite) run system-side with authorize?: false from the
    # operations — the token IS the credential (the MembershipInvite
    # :accept posture). Everyone else is default-forbidden.

    # always() is honest here: the action's actor filter already constrains
    # the result to the caller, so "any authenticated actor may run :me"
    # cannot leak another record (nil actor never reaches policy — the
    # filter errors ReadActionRequiresActor first).
    policy action(:me) do
      description("Any authenticated user reads their own record")
      authorize_if(always())
    end

    # The settings rename (#285 T5): a user sets only their own username.
    # The record-level expression is the owner gate (the :me read above is
    # how the UI loads the record; this policy is what refuses the update).
    # The admin grant lives INSIDE the policy on purpose — applicable
    # policies AND together, so a separate admin policy would still
    # require the owner expression on someone else's record (the
    # UserEmail write-policy posture).
    policy action(:set_username) do
      description("Users rename their own account")
      authorize_if(expr(id == ^actor(:id)))
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
    end
  end

  json_api do
    type("user")

    # The contract's "email" key (#285 T4, #287) serializes the
    # `primary_email` calculation — same key, live value from
    # user_emails (the legacy column is gone; nothing private remains
    # to keep out of the document). The app runs with
    # show_public_calculations_when_loaded?: false, so the route pins
    # its own field list — that list is also what the query loads
    # (ash_json_api loads route default_fields before reading).
    field_names(primary_email: :email)

    routes do
      # GET /api/v1/me — the current actor's record, no id (#24). The only
      # public User surface: deliberately no collection routes (listing
      # users is not a machine API — ADR-0019 §1).
      #
      # #484 (W2b): the meta carries the CALLING token's scope list —
      # the wire introspection MCP tool filtering needs (read domains
      # are probeable via the boundary's 403s; write domains are not).
      # Scopes belong to the token, not the user, so they ride
      # request-scoped meta instead of a field — and a session caller
      # (no PAT ⇒ no context entry, the
      # PutPatScopesInAshContext bridge) gets no key at all: the
      # omission is the honest answer, never null or an empty list.
      # The key is owned by FluxVale.Api.Scopes (the plug writes the
      # same one); a non-list value RAISES — drift must crash, not
      # silently render the session answer for a PAT caller.
      get(:me,
        route: "/me",
        default_fields: [:primary_email, :platform_role, :username],
        metadata: fn _query, _user, request ->
          key = Scopes.pat_scopes_context_key()

          case request.context do
            %{^key => scopes} when is_list(scopes) -> %{scopes: scopes}
            # The plug only writes the row's {:array, :string}; drift
            # must crash, not render the session answer for a caller.
            # coveralls-ignore-next-line
            %{^key => _not_a_list} -> raise "pat scopes context must be a list"
            _no_pat_context -> %{}
          end
        end
      )
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
    # #287: the legacy `email` COLUMN is gone — the signup address is a
    # private `:email` ARGUMENT on :create/:invite (see actions), and
    # `user_emails` is the only address storage. The JIT create's
    # duplicate-signup arbitration rides `user_emails.unique_address`
    # (the verified-primary row SignupEmailRow writes in the same
    # transaction).
    #
    # GitHub-style handle (#285 T2): derived from the signup address by
    # DeriveUsername — the only writer past :set_username. NOT NULL since
    # #287's contract migration: every account carries a handle from
    # birth, invited accounts included (the invite derives one so the
    # constraint holds while the account is inert). Its own namespace
    # among users — organization slugs are never consulted.
    attribute :username, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :platform_role, FluxVale.Identity.Types.PlatformRole do
      allow_nil?(false)
      default(:user)
      public?(true)
    end

    # The #502 invited state — all nullable, nil for every normal
    # account (a normal account answers :none from invite_state).
    # The invite stamps are PRIVATE: no JSON:API surface consumes them
    # (the /me route pins its field list, AshAdmin reads attributes
    # regardless, and the admin dashboard rides domain reads). Public
    # here would grow the OpenAPI user schema and drift the CLI's
    # generated types for nothing.
    attribute :invited_at, :utc_datetime_usec do
      public?(false)
    end

    attribute :invite_accepted_at, :utc_datetime_usec do
      public?(false)
    end

    attribute :invite_withdrawn_at, :utc_datetime_usec do
      public?(false)
    end

    # SHA-256 hex digest of the raw accept token — the only form ever
    # stored (the MembershipInvite posture). Private and sensitive: no
    # serialization surface, never renders in error output.
    attribute :invite_token_hash, :string do
      public?(false)
      sensitive?(true)
    end

    # No attribute default: lazy function defaults fire on EVERY create,
    # which would stamp an invite window on normal JIT accounts too (a
    # fresh signup must carry nil in all five columns). :invite and
    # :reinvite set the window explicitly.
    attribute :invite_expires_at, :utc_datetime do
      public?(false)
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
      accept([:platform_role])

      # The signup address (#287): an argument, not a column —
      # user_emails is the only address storage. PUBLIC by necessity:
      # private arguments cannot ride for_create params nor the code
      # interface (the :invite token_hash lesson) — every caller passes
      # the address by name and keeps its shape. No serialization
      # surface: arguments never render (field lists carry attributes
      # and calculations only), and User exposes no create route.
      argument(:email, :ci_string, allow_nil?: false)

      # Username derivation (#285 T2, #287): reads the :email argument;
      # always producing a 2–39 [a-z0-9-] value; residual failure arms
      # (probe read failure, lost race) fail loudly, like provisioning's.
      # Listed BEFORE ProvisionPersonalOrg: provisioning must see the
      # username — it names the org after it (#285 T7).
      change(DeriveUsername)

      # Every registration path gets an org (#119) — JIT signup, seeds,
      # admin-created users. Runs in the create transaction; see the
      # change module.
      change(ProvisionPersonalOrg)

      # The signup row (#285 T3 §5, #287): same transaction — the
      # account is born with its verified primary user_emails row,
      # written from the :email argument.
      change(SignupEmailRow)
    end

    # /api/v1/me (#24): the actor-template filter is the whole trick — the
    # query can only ever return the caller, and a nil actor fails loudly
    # (ReadActionRequiresActor) before policy runs. Same templating shape
    # as get_by_email's ^arg(:email).
    read :me do
      description("The current actor's own record")
      filter(expr(id == ^actor(:id)))
    end

    # The settings rename (#285 T5): the only :username writer past
    # signup's derivation. require_atomic? false — ValidUsername is a
    # plain function validation Ash cannot run atomically (the same
    # trade Organization's update and the UserEmail guard actions make).
    #
    # No stale-form guard (the Organization.update posture checks
    # StaleRecord in its settings UI): a username addresses nothing — no
    # URL, no links, no redirect — and THIS action is the only rename
    # surface, so a stale view can only lose the same uniqueness race it
    # loses today (the unique_username index is the arbiter). Revisit
    # trigger: a second rename surface (admin tooling, public profiles)
    # — then an optimistic lock.
    update :set_username do
      description("Set the account's username (the settings rename)")
      accept([:username])
      require_atomic?(false)
      validate(ValidUsername, where: changing(:username))
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
    # interface unchanged: callers (seeds) keep their shape.
    # unique_address guarantees at most one row per address, so the get?
    # contract holds.
    #
    # What makes this safe is the `not is_nil(verified_at)` filter in
    # the `exists` clause plus User's own policies — nothing else. The
    # `exists` does NOT apply UserEmail's related-resource policies (no
    # actor predicate appears in the emitted subquery): an unauthorized
    # or nil actor is refused with Forbidden by User's policies before
    # execution ever reaches UserEmail, and the AshAuthentication
    # interaction bypass is what carries the auth flows. A pending
    # address never resolves either way — no unverified leak.
    read :get_by_email do
      description("Get a user by one of their verified email addresses")
      argument(:email, :ci_string, allow_nil?: false)
      get?(true)
      filter(expr(exists(emails, address == ^arg(:email) and not is_nil(verified_at))))
    end

    # The occupant resolution (#287): the account holding ANY row on the
    # address — verified owner or invited reservation alike. One lookup
    # where the frozen-mirror era needed two (verified row, then
    # users.email). Same policy posture as get_by_email: the interaction
    # bypass, platform admins, and system paths running authorize?:
    # false — no public listing surface. unique_address keeps the get?
    # contract (one row per address ⇒ one owner).
    read :get_by_address do
      description("Get the user occupying an email address (verified or reserved)")
      argument(:email, :ci_string, allow_nil?: false)
      get?(true)
      filter(expr(exists(emails, address == ^arg(:email))))
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

    # The admin invite (#502, re-homed #287): creates the pre-provisioned,
    # inert account. Deliberately NOT primary — the JIT signup :create
    # above stays the registration path — and none of its bootstrap
    # changes run here: no ProvisionPersonalOrg. The address arrives as
    # the private :email argument and lands as the invitation's PENDING
    # row (InvitedEmailRow — the reservation; withdrawal and expiry keep
    # it, acceptance flips it). DeriveUsername DOES run here: NOT NULL
    # (#287) means the invited account carries its handle from birth —
    # "inert" keeps no-org, loses no-username. The token hash rides the
    # private argument (the MembershipInvite :create posture) — no
    # caller surface can mint an arbitrary credential shape; invited_at
    # and the expiry window stamp here explicitly (no attribute
    # default — see the attribute comment).
    create :invite do
      # PUBLIC (the :create :email note): the admin surface and the
      # operation pass the address by name.
      argument(:email, :ci_string, allow_nil?: false)

      argument(:token_hash, :string, allow_nil?: false, sensitive?: true, public?: false)
      change(set_attribute(:invite_token_hash, arg(:token_hash)))

      change(DeriveUsername)
      change(InvitedEmailRow)

      change(set_attribute(:invited_at, &DateTime.utc_now/0))
      change(set_attribute(:invite_expires_at, &__MODULE__.invite_expires_at/0))
    end

    # Re-invite (#502): the resend lever. A fresh token (new hash via the
    # private argument), a fresh window, withdrawal cleared — a withdrawn
    # invite is re-issuable, an accepted account is not, and a
    # never-invited live account is not an invitation at all: the filter
    # rides the UPDATE's WHERE (the MembershipInvite :revoke posture), so
    # every mismatch refuses with StaleRecord instead of converting a
    # live account into a pending invite. Record-update flow so that
    # no-match is an answer, not a silent zero-row success.
    update :reinvite do
      description("Refresh the invitation — a new token, a fresh window, withdrawal cleared")
      accept([])

      argument(:token_hash, :string, allow_nil?: false, sensitive?: true, public?: false)
      change(set_attribute(:invite_token_hash, arg(:token_hash)))

      change(set_attribute(:invited_at, &DateTime.utc_now/0))
      change(set_attribute(:invite_expires_at, &__MODULE__.invite_expires_at/0))
      change(set_attribute(:invite_withdrawn_at, nil))

      change(filter(expr(is_nil(invite_accepted_at) and not is_nil(invited_at))))

      require_atomic?(false)
    end

    # Withdraw (#502): idempotent keep-first-stamp — a second call keeps
    # the original stamp (the MembershipInvite :revoke posture). The
    # keep-or-stamp decision evaluates against the ROW, never the
    # caller's struct: the expr is data-layer rendered, so no in-memory
    # struct can move it. An accepted account is not a withdraw target —
    # the filter rides the UPDATE's WHERE and the mismatch answers
    # StaleRecord.
    update :withdraw_invite do
      description("Withdraw an unaccepted invitation")
      accept([])

      # A never-invited account is not a withdraw target either (the
      # :reinvite posture): only an OUTSTANDING invitation can retire.
      change(filter(expr(is_nil(invite_accepted_at) and not is_nil(invited_at))))

      # credo:disable-for-lines:6 Credo.Check.Readability.ParenthesesInCondition
      change(
        atomic_update(
          :invite_withdrawn_at,
          expr(if(is_nil(invite_withdrawn_at), now(), invite_withdrawn_at))
        )
      )

      require_atomic?(false)
    end

    # Accept (#502, re-homed #287): the one-time consume + the full
    # first-login bootstrap, one write. The filter in (1) rides the
    # UPDATE's WHERE and IS the one-time arbiter — a second use, or a
    # race against withdrawal or expiry, matches zero rows and refuses
    # with StaleRecord instead of double-bootstrapping. Then the org
    # provision — and the row flip: the invitation's pending row goes
    # VERIFIED and PRIMARY here (acceptance is the inbox proof — the
    # one-time link IS the credential; AcceptInvitedEmailRow), the same
    # end state the JIT path's SignupEmailRow writes at birth. No
    # DeriveUsername here: the invite already derived the handle.
    update :accept_invite do
      description("Consume the one-time invite — verify, activate, bootstrap in one write")
      accept([])

      change(
        filter(
          expr(
            not is_nil(invited_at) and is_nil(invite_accepted_at) and
              is_nil(invite_withdrawn_at) and invite_expires_at > now()
          )
        )
      )

      change(set_attribute(:invite_accepted_at, &DateTime.utc_now/0))

      change(AcceptInvitedEmailRow)
      change(ProvisionPersonalOrg)

      require_atomic?(false)
    end

    # The invitee token path (#502): resolve by hash — the raw token
    # exists only in the email, the row stores the SHA-256 (the
    # MembershipInvite :get_by_token_hash posture). State rides along so
    # the accept operation never re-derives it.
    read :get_by_invite_token_hash do
      description("Resolve a user by their invite token hash — the invitee accept path")
      get?(true)

      argument(:token_hash, :string, allow_nil?: false, sensitive?: true)
      filter(expr(invite_token_hash == ^arg(:token_hash)))

      prepare(fn query, _context -> Ash.Query.load(query, [:invite_state]) end)
    end
  end

  code_interface do
    domain(FluxVale.Identity)

    define(:create, args: [:email])
    define(:get_by_email, args: [:email])
    define(:get_by_address, args: [:email])
    define(:get_by_username, args: [:username])
    define(:withdraw_invite)

    # :invite and :reinvite have no code interface — their token_hash
    # argument is private (the system operation's minted digest), and
    # the interface's input surface cannot carry private arguments (the
    # MembershipInvite :accept shape: for_create/for_update +
    # set_argument).
  end

  identities do
    # #287: `unique_email` died with the column — duplicate-signup
    # arbitration rides `user_emails.unique_address` (the signup row
    # rides the create transaction).

    # Usernames are unique among users (#285 T2) — a separate namespace
    # from organization slugs, deliberately.
    identity(:unique_username, [:username])

    # The token seam's lookup resolves by hash (get_by_invite_token_hash
    # is a get? read — at most one row may answer; a collision would
    # need a SHA-256 break, the MembershipInvite posture). Nullable:
    # every normal account carries NULL and Postgres unique indexes
    # admit any number of those.
    identity(:unique_invite_token_hash, [:invite_token_hash])
  end

  aggregates do
    # The account's verified primary address (#285 T4) — the value every
    # user-visible surface displays. `first` over the emails join; the
    # partial unique index caps matches at one row, so no sort. Nil when
    # no verified primary row exists. Private plumbing: surfaces read it
    # through the public `primary_email` calculation.
    #
    # authorize?(false) — REQUIRED on the real load paths: without it
    # the surfaces' authorized calc load trips UserEmail's admin-only
    # :read and silently degrades the display to nil — proven three
    # times across the #285 T4 arc (the implementer's roster probe, the
    # architect's full-suite run with the flag removed, and the hostile
    # review's fresh-beam reproduction). CAUTION when probing this: a
    # STALE compiled beam makes the flagless build look clean — force
    # the recompile (mix compile --force) before believing any probe
    # here. The exposure claim stands: one address per user, no more
    # than a per-user join revealed, gated by the loading surface's
    # read policies.
    first :primary_address, :emails, :address do
      filter(expr(is_primary and not is_nil(verified_at)))
      authorize?(false)
    end

    # The invitation's reservation address (#287): the pending,
    # non-primary row an unaccepted invitation holds. Every live
    # account answers primary_address instead — this aggregate only
    # matters for invited accounts, which own exactly one row. Private
    # plumbing for contact_email below; same authorize?(false) stance
    # and exposure claim as primary_address.
    first :invited_address, :emails, :address do
      filter(expr(is_nil(verified_at) and not is_primary))
      authorize?(false)
    end
  end

  calculations do
    # The display email (#285 T4, #287): the verified primary address.
    # HONEST nil when the account has none — post-#287 that is data
    # drift only (every action-created account is born with its
    # verified-primary row; the wipe doctrine absorbed the mirror-era
    # stragglers), so no surface carries a fallback anymore. Loaded
    # with the user at resolution (UserAuth.resolve_user/1) — one query
    # per surface, never an N+1. Public so /api/v1/me can serialize it;
    # field_names renders it under the contract's "email" key.
    calculate :primary_email, :string, expr(primary_address) do
      public?(true)
    end

    # The admin People column (#287): what the surface shows — the
    # PRIMARY address for live accounts, the invitation's reservation
    # for unaccepted ones. Post-#287 the users table carries no
    # address; both arms read user_emails (the aggregates above).
    # Private: one surface's display value, not an API contract.
    #
    # The `if` is Ash.Query.Function.If inside the expr DSL — not
    # Elixir's macro; the parenthesised call is the DSL's required
    # shape, so the readability check is disabled for these lines (the
    # MembershipInvite :state posture).
    #
    # credo:disable-for-lines:4 Credo.Check.Readability.ParenthesesInCondition
    calculate(
      :contact_email,
      :string,
      expr(if(is_nil(primary_address), invited_address, primary_address))
    )

    # The invite lifecycle axis (#502) — one definition so the
    # operations and any future admin surface cannot drift (order
    # matters: a never-invited account is :none; accepted wins over a
    # later withdrawal stamp, withdrawal wins over expiry).
    #
    # The `if` is Ash.Query.Function.If inside the expr DSL — not
    # Elixir's macro; the parenthesised call is the DSL's required
    # shape, so the readability check is disabled for this block (the
    # MembershipInvite :state posture).
    #
    # credo:disable-for-lines:20 Credo.Check.Readability.ParenthesesInCondition
    calculate(
      :invite_state,
      :atom,
      expr(
        if(
          is_nil(invited_at),
          :none,
          if(
            not is_nil(invite_accepted_at),
            :accepted,
            if(
              not is_nil(invite_withdrawn_at),
              :withdrawn,
              if(invite_expires_at <= now(), :expired, :pending)
            )
          )
        )
      )
    )
  end

  @doc "The invite window in days — the mail copy reads it (see the @invite_ttl_days comment)"
  @spec invite_ttl_days() :: pos_integer()
  def invite_ttl_days, do: @invite_ttl_days

  @doc "The invite window's default stamp: the TTL days from now"
  @spec invite_expires_at() :: DateTime.t()
  def invite_expires_at do
    DateTime.add(DateTime.utc_now(), @invite_ttl_days * 24 * 60 * 60, :second)
  end

  @doc """
  SHA-256 hex digest of a raw invite token — the only thing ever stored.
  Lives here because the minting operation and the token lookup need the
  identical digest; the resource owns `invite_token_hash` (the
  MembershipInvite posture).
  """
  @spec token_hash(String.t()) :: String.t()
  def token_hash(raw) do
    :sha256
    |> :crypto.hash(raw)
    |> Base.encode16(case: :lower)
  end
end

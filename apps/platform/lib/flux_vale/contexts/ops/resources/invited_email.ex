defmodule FluxVale.Ops.InvitedEmail do
  @moduledoc """
  One early-access invitation (#478, final shape Nov 6): the admin
  enters an email address, the invite is recorded, and an invitation
  email goes out. The ADDRESS is the credential — per-address matching,
  never per domain (a second address at an invited address's domain is
  still refused). `@fluxvale.com` needs no row: the team bypass is
  structural in `Ops.InvitedEmails`.

  `revoked_at` is the off switch: a revoked row stays listed but admits
  nothing, and revocation never touches an account that already
  exists — the gate runs at first-time provisioning only.

  The invitation email rides the create action's after_action hook
  (`DeliverInvitation`, the AccessRule BustCache posture): it is
  informational — no token, no link credential, the gate is the row.

  Managed in AshAdmin (Ops domain): list, add (which IS the invite),
  revoke. Evaluation runs through `Ops.InvitedEmails` (the only
  sanctioned evaluator, the AccessRules posture).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Ops,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("invited_emails")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")
  end

  policies do
    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description("Platform admins manage early-access invitations (#478, ADR-0027, ADR-0030)")
      authorize_if(always())
    end

    # Everything else — including anonymous/default reads — is denied.
    # The gate's evaluator read runs authorize?: false
    # (Ops.InvitedEmails): the invitation list is global config consulted
    # mid-authentication, not actor-scoped data — the AccessRules
    # evaluator's posture. The sign-in UI never reads this table.
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :address, :ci_string do
      allow_nil?(false)
      public?(true)
      # The invited address, exactly. ci_string both directions: matching
      # is case-insensitive AND the unique index is too (a differently-
      # cased duplicate would be data integrity rot, the AccessRule
      # posture).
    end

    attribute :revoked_at, :utc_datetime_usec do
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:address])
      # The same address shape the code-send gate enforces: an
      # unsendable invitation would sit silently inert
      change(FluxVale.Ops.InvitedEmail.ValidateAddress)
      change(FluxVale.Ops.InvitedEmail.DeliverInvitation)
    end

    update :revoke do
      # Immediate and idempotent: revoking a revoked invite keeps the
      # first stamp (the membership_invite revoked_at pattern).
      #
      # credo:disable-for-next-line Credo.Check.Readability.ParenthesesInCondition
      change(atomic_update(:revoked_at, expr(if(is_nil(revoked_at), now(), revoked_at))))
    end
  end

  identities do
    identity(:unique_address, [:address])
  end
end

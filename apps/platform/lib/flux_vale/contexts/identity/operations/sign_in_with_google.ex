defmodule FluxVale.Identity.Operations.SignInWithGoogle do
  @moduledoc """
  Signs a user in from Google-attested OIDC claims (#642,
  [ADR-0003](../../../../../../docs/adr/00003-ashauthentication-drop-authentik.md)
  Am. 4): the strictly-gated `email_verified` claim stands in for
  VerifyAuthCode's burned code, and resolution runs the SAME admission
  ladder rung for rung (plan §3.3) — supersede, re-lookup, occupant,
  team-domain JIT, `AccessRules` — then mints the standard 60-day
  session.

  The strict gate first (plan §4): anything but a literal `true`
  `email_verified` refuses BEFORE any lookup — an unusable claim
  (missing or malformed email included) is an unverified claim, and
  an unverified claim can never reach resolution. That gate, the one
  fixed IdP, and the address being the system's own primary
  identifier are what make the auto-link defensible.

  A verified `user_emails` row signs in to its owner — that IS the
  auto-link: a Google-attested inbox proves the identifier the
  system already trusts, so an existing account is reused, never
  forked. A PENDING claim carries no proof and is superseded by the
  Google proof exactly as the burned code supersedes it; invited
  reservations never supersede — the occupant lookup finds the
  invited account and its invite state decides (#502): pending
  answers :invite_pending (the emailed link is the credential),
  retired invitations answer :invitation_required like any uninvited
  address.

  The user-level AccessRule gate at the mint is deliberately
  stricter than the native email+code branch (whose re-entry
  protection lives in SessionController, #26): one hop, both gates.
  """

  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRules

  # Ash.Query.filter is a macro
  # The framework's own door for auth flows — see RequestAuthCode's note
  @interaction %{private: %{ash_authentication?: true}}

  # The team bypass's domain — VerifyAuthCode's @team_domain is the
  # TWIN (operations own their constants; plan §11 names the drift
  # risk: when the invitation wall lifts, edit both, once).
  @team_domain "fluxvale.com"

  @doc """
  Resolves Google-verified `claims` (the assent user map: `"email"`,
  `"email_verified"`). On success returns `{:ok, user, token}`;
  failures are the plan §3.3 atom set — `:email_not_verified` (the
  strict gate), `:not_allowed` (AccessRules, address level at entry
  and user level at the mint), the invitation ladder
  (`:invite_pending`, `:invitation_required`), and the VerifyAuthCode
  residuals (`:address_unresolved` — the retryable post-supersede
  race window; `:user_lookup_failed` — the DB-read arm;
  `:provisioning_failed` — a non-uniqueness create failure in the
  residual window). Assent-level failures (Google unreachable, code
  refused, bad state) never reach this operation — they happen in the
  OIDC hop before any claims exist.
  """
  @spec call(map()) :: {:ok, map(), String.t()} | {:error, atom()}
  def call(claims) do
    result = resolve(claims)

    # The outcome counter (plan §10): one event on EVERY return path,
    # outcome-tagged, no PII — the event name lives on the domain
    # beside signup_event/0 so the web layer and tests share it.
    :telemetry.execute(FluxVale.Identity.google_sign_in_event(), %{count: 1}, %{
      outcome: outcome_atom(result)
    })

    result
  end

  defp outcome_atom({:ok, _user, _token}), do: :ok
  defp outcome_atom({:error, atom}) when is_atom(atom), do: atom

  # The strict gate (plan §3.3 step 1, §4 guardrail 1 —
  # non-negotiable): a literal `true` and a usable email, or a refusal
  # BEFORE any lookup. The `=== true` keeps "true"-the-string and
  # every other truthy shape out; a missing/malformed email is the
  # same refusal (an unusable claim is an unverified claim).
  defp resolve(claims) do
    email = claims["email"]

    if claims["email_verified"] === true and is_binary(email) and email != "" do
      with :ok <- AccessRules.ensure_allowed(email) do
        resolve_email(email)
      end
    else
      {:error, :email_not_verified}
    end
  end

  defp resolve_email(email) do
    case lookup_user(email) do
      # This IS the auto-link (plan §4): the claims resolve through
      # the same verified-row lookup the email arm rides — sign in to
      # the existing account, no fork, no identity row.
      {:ok, user} ->
        mint(user)

      {:error, :not_found} ->
        supersede_and_resolve(email)

      # coveralls-ignore-start - DB read failure mid-flow: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The VerifyAuthCode ladder, rung for rung (plan §3.3 step 4): the
  # Google proof supersedes a PENDING claim exactly as the burned
  # code does — atomic, pending-only at delete time, invited
  # reservations exempt (#287). The RE-LOOKUP is the point: a
  # concurrent VerifyEmail that flips a claim verified between the
  # supersede and now resolves to its owner instead of forking a
  # second account.
  defp supersede_and_resolve(email) do
    UserEmail.supersede_pending_claims(email)

    case lookup_user(email) do
      # coveralls-ignore-start - race arm: needs the concurrent
      # VerifyEmail's flip to commit between the supersede and this
      # read — true concurrency, not sequential
      {:ok, user} ->
        mint(user)

      # coveralls-ignore-stop

      {:error, :not_found} ->
        provision_user(email)

      # coveralls-ignore-start - DB read failure mid-flow: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp lookup_user(email) do
    result =
      User
      |> Ash.Query.for_read(:get_by_email, %{email: email})
      |> Ash.Query.set_context(@interaction)
      |> Ash.read()

    case result do
      {:ok, [user]} ->
        {:ok, user}

      {:ok, []} ->
        {:error, :not_found}

      # Infra failure propagates a defined shape instead of raising a
      # CaseClauseError mid-resolution (the VerifyAuthCode posture)
      # coveralls-ignore-start - DB read failure mid-flow: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} ->
        {:error, :user_lookup_failed}
        # coveralls-ignore-stop
    end
  end

  # JIT provisioning (plan §3.3 step 4): the Google proof earned the
  # inbox claim; admission rides the structural team bypass — EXCEPT
  # for an address another account already occupies: the occupant
  # lookup sees every row (verified owner or invited reservation),
  # and the invite state decides (invited_owner/1). The refusal
  # happens before any write.
  defp provision_user(email) do
    case occupant(email) do
      {:ok, %User{} = owner} ->
        invited_owner(owner)

      {:ok, nil} ->
        gated_create(email)

      # coveralls-ignore-start - DB read failure mid-flow: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} ->
        {:error, :user_lookup_failed}
        # coveralls-ignore-stop
    end
  end

  # The occupant's invite state decides (#502), the VerifyAuthCode
  # ladder verbatim: a PENDING invite is an inert pre-provisioned
  # account — never signed into (the link is the credential);
  # :withdrawn and :expired are retired invitations, so the JIT
  # gate's refusal is the honest answer. :none and :accepted are
  # structurally unreachable HERE (verified owners were caught by
  # lookup_user, their pending claims superseded above); the race
  # residual rides :address_unresolved, retryable.
  defp invited_owner(%User{} = owner) do
    case owner.invite_state do
      :pending ->
        {:error, :invite_pending}

      state when state in [:withdrawn, :expired] ->
        {:error, :invitation_required}

      # coveralls-ignore-start - race-only: needs a claim to commit
      # between the supersede and the occupant lookup — true
      # concurrency, not sequential (see @doc for the atom)
      state when state in [:none, :accepted] ->
        {:error, :address_unresolved}

        # coveralls-ignore-stop
    end
  end

  # The gate + create (#502): the structural team bypass is the only
  # JIT door left — a pre-provisioned invited account already exists
  # by the time it matters (invited_owner/1 answers :invite_pending
  # above, never here).
  defp gated_create(email) do
    if team_address?(email) do
      create_and_resolve(email)
    else
      {:error, :invitation_required}
    end
  end

  # Case-insensitive exact-suffix match — a subdomain or a lookalike
  # suffix is not the team (the VerifyAuthCode twin).
  defp team_address?(address) do
    downcased =
      address
      |> to_string()
      |> String.downcase()

    String.ends_with?(downcased, "@" <> @team_domain)
  end

  defp create_and_resolve(email) do
    case create_user(email) do
      {:ok, user} ->
        # The signup-success point (business telemetry): same
        # semantic event as the email arm's JIT signup — one event,
        # three fire sites now (VerifyAuthCode, AcceptInvitation,
        # here); the listener is FluxValeWeb.Telemetry (the name
        # lives on the domain, FluxVale.Identity.signup_event/0).
        :telemetry.execute(FluxVale.Identity.signup_event(), %{count: 1}, %{})

        mint(user)

      # The address already belongs to an account our lookups missed:
      # a row that committed in the residual window between the
      # occupant lookup above and this create (the VerifyAuthCode
      # review's P2-1) — user_emails.unique_address is the collision
      # identity. The Google proof still holds; only a uniqueness
      # violation means "address already owned" (resolve_collision/2);
      # anything else (a validation, a cap trigger, a DB failure) is
      # not that signal.
      {:error, collision} ->
        # coveralls-ignore-start - race-only: the occupant pre-check
        # is the sequential arbiter, so a create failure needs a
        # commit in the residual window — true concurrency, not
        # sequential. The pre-check is the gate's existing-accounts
        # carve-out and stays.
        resolve_collision(collision, email)
        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start - race-only with the occupant pre-check:
  # reached only from the concurrent-commit window above. The
  # unique/non-unique split matters for the race arms' shapes; the
  # non-uniqueness fall-through is the same not-simulatable class as
  # the other DB-down arms.
  defp resolve_collision(collision, email) do
    if unique_collision?(collision) do
      resolve_collided(email)
    else
      {:error, :provisioning_failed}
    end
  end

  # coveralls-ignore-stop

  # A collision is a uniqueness violation on the address identity —
  # user_emails.unique_address, the signup row riding the create (#287
  # — the VerifyAuthCode twin, verbatim). AshPostgres reports the
  # violated constraint in the error's private_vars; anything else (a
  # validation, a cap trigger, a DB failure) is not an "address
  # already owned" signal.
  #
  # coveralls-ignore-start - the whole matcher cluster is race-only
  # with the occupant pre-check: no sequential writer reaches the
  # create past it, so these run only inside the concurrent-commit
  # window.
  defp unique_collision?(%Ash.Error.Invalid{} = error) do
    Enum.any?(error.errors, &unique_constraint_error?/1)
  end

  # a non-Invalid error class on the JIT create is a DB failure —
  # the same class as the other DB-down arms
  defp unique_collision?(_other_class), do: false

  defp unique_constraint_error?(%Ash.Error.Changes.InvalidAttribute{} = error) do
    unique_attribute?(error) and unique_constraint?(error)
  end

  # the collision error carries a single attribute error (the probes'
  # shapes); a non-attribute member would need a concurrent
  # multi-error commit
  defp unique_constraint_error?(_error), do: false

  defp unique_attribute?(%{field: :address}), do: true

  # the other reachable attribute arms are intercepted earlier by the
  # occupant pre-check; a username/org-slug probe race (DeriveUsername,
  # ProvisionPersonalOrg — same-local-part signups) CAN deliver its
  # field here under true concurrency: the fall-through runs and
  # routes it to :provisioning_failed, atom-shaped — a retry probes
  # the next suffix.
  defp unique_attribute?(_error), do: false

  defp unique_constraint?(error) do
    Keyword.get(error.private_vars || [], :constraint_type) == :unique
  end

  # coveralls-ignore-stop

  defp create_user(email) do
    User
    |> Ash.Changeset.for_create(:create, %{email: email})
    |> Ash.Changeset.set_context(@interaction)
    |> Ash.create()
  end

  # coveralls-ignore-start - race-only cluster since #287: the
  # occupant pre-check is the sequential arbiter, so every arm in
  # here needs a commit inside the concurrent window (the flip
  # between the re-lookup and the create) or a DB read failure
  # mid-flow (the health db_up? class — not simulatable under the
  # sandbox)
  defp resolve_collided(email) do
    case lookup_user(email) do
      # The concurrent VerifyEmail's row landed inside the window —
      # that account is the proven owner.
      {:ok, user} ->
        mint(user)

      {:error, :not_found} ->
        collide_with_occupant(email)

      {:error, _read_failed} = error ->
        error
    end
  end

  # coveralls-ignore-stop

  # The create collided, so a row existed moments ago: an invited
  # reservation (its account decides the refusal — the invitation
  # wins, it existed first) or a claim that already vanished
  # mid-window. Race-only either way — a clean, retryable refusal.
  # coveralls-ignore-start
  defp collide_with_occupant(email) do
    case occupant(email) do
      {:ok, %User{} = owner} ->
        invited_owner(owner)

      _owner_gone ->
        {:error, :address_unresolved}
    end
  end

  # coveralls-ignore-stop

  # The occupant lookup (#287): one read where the mirror era needed
  # two — any row on the address resolves its owner, verified or
  # reserved. invite_state loads with the query: invited_owner/1
  # decides on it.
  defp occupant(email) do
    User
    |> Ash.Query.for_read(:get_by_address, %{email: email})
    |> Ash.Query.load(:invite_state)
    |> Ash.read_one(authorize?: false)
  end

  # Plan §3.3 steps 5–6: the user-level gate at the mint (one hop,
  # both gates — deliberately stricter than the native email+code
  # branch), then the standard 60-day token — the same store,
  # revocation, and TTL as every session.
  defp mint(user) do
    with :ok <- AccessRules.ensure_allowed_user(user),
         {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user) do
      {:ok, user, token}
    end
  end
end

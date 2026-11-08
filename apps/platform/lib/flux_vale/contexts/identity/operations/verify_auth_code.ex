defmodule FluxVale.Identity.Operations.VerifyAuthCode do
  @moduledoc """
  Verifies a one-time login code
  ([ADR-0003](../../../../../../docs/adr/00003-ashauthentication-drop-authentik.md),
  #21): single-use consumption
  (the optimistic-locked delete is the arbiter), capped attempts enforced
  atomically at the database, JIT provisioning on first sign-in, and the
  standard 60-day session mint on success.

  The AccessRule gate runs before anything else (#26): a rule removed
  after a code was already sent must still stop the session mint — the
  ≤10-min code-TTL window is exactly the severing case Am. 1 cares about.
  Denied addresses burn nothing.

  Resolution is table-backed (#285 T3, #287): a VERIFIED `user_emails`
  row signs in to its user — any verified address, primary or not; a
  PENDING claim carries no proof and is superseded by the burned code
  (deleted atomically — pending-only at delete time — then a fresh JIT
  account). An INVITED reservation is not a claim and never supersedes:
  the occupant lookup (`get_by_address`) finds the invited account and
  the invite state decides (#502) — pending answers :invite_pending (the
  link is the credential), retired invitations (:withdrawn, :expired)
  answer :invitation_required like any uninvited address.

  The invitation rule (#502): JIT provisioning is the team domain's
  alone — a genuinely new address creates an account only on
  `@fluxvale.com`. Everyone else arrives pre-provisioned: an admin's
  invite creates the User (inert, its address already reserved as a
  pending row), and the one-time accept link runs the bootstrap
  (`FluxVale.Identity.accept_invitation/1`). The refusal atom is
  `:invitation_required` — the honest copy is the LiveView's concern;
  the operation's contract is the atom and the no-account guarantee.
  """

  alias FluxVale.Identity.AuthCode
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRules

  # Ash.Query.filter is a macro
  # The framework's own door for auth flows — see RequestAuthCode's note
  @interaction %{private: %{ash_authentication?: true}}

  # The team bypass's domain (#478's structural core, kept by #502):
  # the company's own domain creates freely, no invitation and nothing
  # to manage. Owned here outright — every operation owns its constants.
  @team_domain "fluxvale.com"

  @doc """
  Verifies `code` for `email`. On success returns `{:ok, user, token}`;
  failures are uniform in shape — no account-enumeration signal between
  an unknown address and a bad code. An address that is neither on the
  team domain nor already invited (pre-provisioned) is refused at
  provisioning with `{:error, :invitation_required}` and no account is
  created (#502); an invited-unaccepted account refuses with
  `{:error, :invite_pending}`. `{:error, :address_unresolved}` is the
  residual-window atom (a claim committed between the supersede and the
  occupant lookup — race-only, retryable: the retry supersedes and
  wins; the sign-in UI renders it as the plain bad-code copy, the
  honest answer for a window the user cannot act on).
  """
  @spec call(String.t() | Ash.CiString.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, atom()}
  def call(email, code) do
    with :ok <- AccessRules.ensure_allowed(email) do
      verify(email, code)
    end
  end

  defp verify(email, code) do
    # Guards can't call remote functions — bind the cap first
    max_attempts = AuthCode.max_attempts()

    case latest_active_code(email) do
      nil ->
        {:error, :no_active_code}

      %AuthCode{attempts: attempts} = _exhausted when attempts >= max_attempts ->
        # The cap is the backoff: an exhausted code forces a resend, and
        # resends are throttled — escalating time-out by construction
        {:error, :locked_out}

      %AuthCode{} = auth_code ->
        attempt_verify(auth_code, email, code)
    end
  end

  defp latest_active_code(email) do
    email
    |> active_codes()
    |> List.first()
  end

  defp active_codes(email) do
    AuthCode
    |> Ash.Query.for_read(:active_for_email, %{email: email})
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.set_context(@interaction)
    |> Ash.read!()
  end

  defp attempt_verify(auth_code, email, code) do
    if Bcrypt.verify_pass(code, auth_code.code_hash) do
      consume_and_mint(auth_code, email)
    else
      register_wrong_attempt(auth_code)
    end
  end

  # The burn is the arbiter (optimistic lock on the resource): only the
  # request that actually consumed the code mints a session — the TOCTOU
  # loser gets a clean failure (review finding: CWE-367)
  defp consume_and_mint(auth_code, email) do
    case burn(auth_code) do
      :ok ->
        with {:ok, user} <- ensure_user(email),
             {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user) do
          {:ok, user, token}
        end

      # coveralls-ignore-start - TOCTOU loser arm (CWE-367): needs the code
      # burned between fetch and burn — true concurrency, not sequential
      {:error, _lost_the_race} ->
        {:error, :no_active_code}
        # coveralls-ignore-stop
    end
  end

  defp register_wrong_attempt(auth_code) do
    result =
      auth_code
      |> Ash.Changeset.for_update(:register_attempt)
      |> Ash.Changeset.set_context(@interaction)
      |> Ash.update()

    case result do
      {:ok, _row} ->
        {:error, :wrong_code}

      # The atomic cap guard refused the increment (review: CWE-307)
      # coveralls-ignore-start - race-only: the pre-check catches the cap
      # first in any sequential flow (CWE-307's window is concurrent)
      {:error, _at_cap} ->
        {:error, :locked_out}
        # coveralls-ignore-stop
    end
  end

  defp burn(auth_code) do
    auth_code
    |> Ash.Changeset.for_destroy(:burn)
    |> Ash.Changeset.set_context(@interaction)
    |> Ash.destroy()
  end

  defp ensure_user(email) do
    case lookup_user(email) do
      {:ok, user} ->
        {:ok, user}

      {:error, :not_found} ->
        supersede_and_resolve(email)

      # coveralls-ignore-start - DB read failure mid-verify: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # A PENDING claim (someone started adding this address to another
  # account) carries no proof — the burned code IS the inbox proof, and
  # it supersedes the claim. The supersede is atomic and pending-only at
  # delete time (UserEmail.supersede_pending_claims/1), and invited
  # reservations are exempt (#287): the invited account keeps its row
  # and is found by the occupant lookup below, not forked around. A
  # claim the concurrent VerifyEmail flips verified first SURVIVES:
  # deleted BEFORE the JIT create so the unique_address identity cannot
  # collide with the signup row the create writes — and when it
  # survives, the re-lookup resolves to its owner instead of forking a
  # second account.
  defp supersede_and_resolve(email) do
    UserEmail.supersede_pending_claims(email)

    case lookup_user(email) do
      # A VERIFIED row for the address now exists — the concurrent
      # VerifyEmail's flip committed between our supersede and this
      # read. That account holds the inbox proof; resolve to it — a
      # sign-in, ungated (the allowlist admits accounts, not logins).
      # coveralls-ignore-start - race arm: needs the flip to commit
      # inside this window — true concurrency, not sequential
      {:ok, user} ->
        {:ok, user}

      # coveralls-ignore-stop

      {:error, :not_found} ->
        provision_user(email)

      # coveralls-ignore-start - DB read failure mid-verify: same class
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
      # CaseClauseError AFTER the code was consumed (review finding)
      # coveralls-ignore-start - DB read failure mid-verify: same class as
      # health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} ->
        {:error, :user_lookup_failed}
        # coveralls-ignore-stop
    end
  end

  # JIT provisioning (ADR-0003): a valid code proves inbox ownership.
  # The gate sits in front of the create (#502 shape) — EXCEPT for an
  # address another account already occupies: the occupant lookup sees
  # every row (verified owner or invited reservation), and the invite
  # state decides what may happen (invited_owner/2 below). For a
  # genuinely new address the burned login code proved the inbox and
  # admission rides the structural team bypass. The refusal happens
  # before any write.
  defp provision_user(email) do
    case occupant(email) do
      {:ok, %User{} = owner} ->
        invited_owner(owner)

      {:ok, nil} ->
        gated_create(email)

      # coveralls-ignore-start - DB read failure mid-verify: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} ->
        {:error, :user_lookup_failed}
        # coveralls-ignore-stop
    end
  end

  # The occupant's invite state decides (#502): a PENDING invite is an
  # inert pre-provisioned account — never signed into (the link is the
  # credential, :invite_pending); :withdrawn and :expired are retired
  # invitations, so the JIT gate's refusal is the honest answer.
  # :none and :accepted are structurally unreachable HERE: verified
  # owners were caught by lookup_user, and their pending claims were
  # superseded above — the only rows that survive to this lookup are
  # invited reservations. The race residual (a claim committed after
  # the supersede, inside this window) rides the same arm as every
  # other unresolved-window case: :address_unresolved, retryable — a
  # retry supersedes and wins.
  defp invited_owner(%User{} = owner) do
    case owner.invite_state do
      :pending ->
        {:error, :invite_pending}

      state when state in [:withdrawn, :expired] ->
        {:error, :invitation_required}

      # coveralls-ignore-start - race-only: needs a claim to commit
      # between the supersede and the occupant lookup — true
      # concurrency, not sequential (see the @doc for the atom)
      state when state in [:none, :accepted] ->
        {:error, :address_unresolved}

        # coveralls-ignore-stop
    end
  end

  # The gate + create (#502): the structural team bypass is the only
  # JIT door left — a pre-provisioned invited account already exists by
  # the time it matters (invited_owner/2 hands :pending to
  # :invite_pending above, never here).
  defp gated_create(email) do
    if team_address?(email) do
      create_and_resolve(email)
    else
      {:error, :invitation_required}
    end
  end

  # Case-insensitive exact-suffix match — a subdomain or a lookalike
  # suffix is not the team.
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
        # The signup-success point (business telemetry): seed/admin
        # creates never pass through here, so this counts signups only —
        # the collision arms below are sign-ins to existing accounts.
        # One semantic event, two fire sites — the invite-acceptance
        # twin is AcceptInvitation; the listener is FluxValeWeb.Telemetry
        # (the name lives on the domain, FluxVale.Identity.signup_event/0).
        :telemetry.execute(FluxVale.Identity.signup_event(), %{count: 1}, %{})

        {:ok, user}

      # The address already belongs to an account our lookups missed:
      # a row that committed in the residual window between the
      # occupant lookup above and this create (review P2-1) — the
      # signup row rides the create, so user_emails.unique_address is
      # the collision identity. The burned code is still the inbox
      # proof; only a uniqueness violation means "address already
      # owned" (resolve_collision/2); anything else (a validation, a
      # cap trigger, a DB failure) is not that signal.
      {:error, collision} ->
        # coveralls-ignore-start - race-only: the occupant pre-check is
        # the sequential arbiter, so a create failure needs a commit in
        # the residual window (review P2-1) — true concurrency, not
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
  # user_emails.unique_address, the signup row riding the create (#287:
  # users.unique_email died with the column). AshPostgres reports the
  # violated constraint in the error's private_vars; anything else (a
  # validation, a cap trigger, a DB failure) is not an "address already
  # owned" signal.
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
  # field here under true concurrency: the fall-through runs and routes
  # it to :provisioning_failed, atom-shaped — a retry probes the next
  # suffix.
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

  defp resolve_collided(email) do
    case lookup_user(email) do
      # The concurrent VerifyEmail's row landed inside the window —
      # that account is the proven owner.
      # coveralls-ignore-start - race arm: needs the flip to commit
      # between the re-lookup and the create — true concurrency
      {:ok, user} ->
        {:ok, user}

      # coveralls-ignore-stop

      {:error, :not_found} ->
        collide_with_occupant(email)

      # coveralls-ignore-start - DB read failure mid-verify: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The create collided, so a row existed moments ago: an invited
  # reservation (its account decides the refusal — the invitation wins,
  # it existed first) or a claim that already vanished mid-window.
  # Race-only either way — a clean, retryable refusal.
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
  # reserved. invite_state loads with the query: invited_owner/2
  # decides on it.
  defp occupant(email) do
    User
    |> Ash.Query.for_read(:get_by_address, %{email: email})
    |> Ash.Query.load(:invite_state)
    |> Ash.read_one(authorize?: false)
  end
end

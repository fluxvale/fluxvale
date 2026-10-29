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

  Resolution is table-backed (#285 T3): a VERIFIED `user_emails` row
  signs in to its user — any verified address, primary or not; a
  PENDING claim carries no proof and is superseded by the burned code
  (deleted atomically — pending-only at delete time — then a fresh JIT
  account); no row JITs as before. A claim the concurrent VerifyEmail
  flips verified first is a PROVEN address: its owner signs in, no
  second account. A create collision resolves the account that already
  holds the address — the old-pod shape (`users.email` set, no row,
  review P2-3) gets its mirror row healed and signs in.
  """

  alias FluxVale.Identity.AuthCode
  alias FluxVale.Identity.User
  alias FluxVale.Identity.User.MirrorSignupEmail
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRules

  # Ash.Query.filter is a macro
  require Ash.Query

  # The framework's own door for auth flows — see RequestAuthCode's note
  @interaction %{private: %{ash_authentication?: true}}

  @doc """
  Verifies `code` for `email`. On success returns `{:ok, user, token}`;
  failures are uniform in shape — no account-enumeration signal between
  an unknown address and a bad code.
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
  # delete time (UserEmail.supersede_pending_claims/1), so a claim the
  # concurrent VerifyEmail flips verified first SURVIVES: deleted BEFORE
  # the JIT create so the unique_address identity cannot collide with
  # the mirror row the create writes (#285 T3 §2/§5) — and when it
  # survives, the re-lookup resolves to its owner instead of forking a
  # second account.
  defp supersede_and_resolve(email) do
    UserEmail.supersede_pending_claims(email)

    case lookup_user(email) do
      # A VERIFIED row for the address now exists — the concurrent
      # VerifyEmail committed between our supersede and this read.
      # That account holds the inbox proof; resolve to it.
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

  # JIT provisioning (ADR-0003): a valid code proves inbox ownership
  defp provision_user(email) do
    case create_user(email) do
      {:ok, user} ->
        {:ok, user}

      # The address already belongs to an account our lookups missed:
      # the old-pod shape (users.email holds it, no user_emails row —
      # review P2-3), or a verified row that committed in the residual
      # window between the re-lookup above and this create (review
      # P2-1). Either way the burned code is still the inbox proof —
      # resolve THAT account; no second account, no lost verified stamp.
      # Only the two uniqueness identities mean that, though: any other
      # create failure routes into the heal and gets reinterpreted as
      # one (review round 2, P3 — that match is what turned the P1
      # primary-index failure into a silent wrong-arm write).
      {:error, collision} ->
        if unique_collision?(collision) do
          resolve_collided(email)
        else
          # coveralls-ignore-start - non-uniqueness create failures are
          # not sequentially reachable: format is refused at code-send,
          # username/org-slug collisions are probed away by their
          # changes (DeriveUsername, ProvisionPersonalOrg), and DB
          # failures are the same class as the other DB-down arms
          {:error, :provisioning_failed}
          # coveralls-ignore-stop
        end
    end
  end

  # A collision is a uniqueness violation on the address identities —
  # users.unique_email or user_emails.unique_address (the mirror write
  # riding the create). AshPostgres reports the violated constraint in
  # the error's private_vars; anything else (a validation, a cap
  # trigger, a DB failure) is not an "address already owned" signal.
  defp unique_collision?(%Ash.Error.Invalid{} = error) do
    Enum.any?(error.errors, &unique_constraint_error?/1)
  end

  # coveralls-ignore-start - a non-Invalid error class on the JIT
  # create is a DB failure — the same class as the other DB-down arms,
  # not simulatable under the sandbox
  defp unique_collision?(_other_class), do: false
  # coveralls-ignore-stop

  defp unique_constraint_error?(%Ash.Error.Changes.InvalidAttribute{} = error) do
    unique_attribute?(error) and unique_constraint?(error)
  end

  # coveralls-ignore-start - the collision error carries a single
  # attribute error (the probes' shapes); a non-attribute member would
  # need a concurrent multi-error commit
  defp unique_constraint_error?(_error), do: false
  # coveralls-ignore-stop

  defp unique_attribute?(%{field: field}) when field in [:email, :address], do: true

  # coveralls-ignore-start - the other reachable attribute arms are
  # gone or intercepted earlier: the :user_id partial-index violation
  # is unreachable because the heal's primary decision runs inside the
  # transaction, after EnforceEmailCap's FOR UPDATE lock on the user
  # row — the same lock SetPrimary holds while promoting — so a
  # concurrent promotion can no longer commit between the heal's count
  # and its insert (round-4 fix; before it, this arm caught exactly
  # that race). Username/org-slug identities are probed away by their
  # changes (DeriveUsername, ProvisionPersonalOrg) — race-only residue
  defp unique_attribute?(_error), do: false
  # coveralls-ignore-stop

  defp unique_constraint?(error) do
    Keyword.get(error.private_vars || [], :constraint_type) == :unique
  end

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
        heal_old_pod_user(email)

      # coveralls-ignore-start - DB read failure mid-verify: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The old-pod shape: a pre-T3 pod created the user with `users.email`
  # but no `user_emails` row, so the table-backed lookups miss and the
  # create collides on users.unique_email. The burned code is still the
  # inbox proof: fetch THAT user (authorize?: false, system seam) and
  # write the mirror row exactly as the create path would — riding the
  # same :add changeset so the cap and validation hold, primary only
  # when the account has none yet (a healed account may own one already;
  # forcing it would collide the partial index — review round 2, P1).
  # One-time re-login posture stands (ADR-0023 Am. 1); the F1 sweep
  # closes the residue.
  defp heal_old_pod_user(email) do
    case frozen_email_owner(email) do
      {:ok, %User{} = user} ->
        case MirrorSignupEmail.write_mirror_row(user) do
          {:ok, _mirror_row} ->
            {:ok, user}

          # The heal's write was refused (the cap, a DB failure — the
          # uniqueness arms are routed away from here by
          # unique_collision?/1). The bare-with used to leak the
          # %Ash.Error.Invalid{} class out of call/2, breaking its
          # {:error, atom()} contract — same public shape as the
          # owner-gone arm below.
          {:error, _refused} ->
            {:error, :address_unresolved}
        end

      # The create just collided on this address, so an owner existed
      # moments ago: it vanished mid-window, or the collision was a
      # claim re-added inside the window (unique_address) with no
      # old-pod owner. Race-only either way — a clean failure; the
      # retry supersedes and wins.
      # coveralls-ignore-start
      _owner_gone ->
        {:error, :address_unresolved}
        # coveralls-ignore-stop
    end
  end

  # users.email is the frozen mirror the old pods resolve through —
  # reading it directly is the only way to find an account the
  # table-backed identity cannot see yet.
  defp frozen_email_owner(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(authorize?: false)
  end
end

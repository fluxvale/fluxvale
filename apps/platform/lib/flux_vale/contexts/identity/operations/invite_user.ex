defmodule FluxVale.Identity.Operations.InviteUser do
  @moduledoc """
  The one admin invite verb (#502): create the pre-provisioned account
  or re-issue an outstanding invitation, then deliver the one-time
  accept link. Inviting IS a User row plus one email — no separate
  invitation resource.

  Occupant resolution reads ONE surface (#287): any `user_emails` row
  on the address resolves its owner — verified owner or invited
  reservation alike (`get_by_address`; the mirror-era second lookup
  died with the column). An active account (:none, or :accepted)
  refuses with :already_active; an invited account (pending,
  withdrawn, expired) re-issues; an unoccupied address creates.

  The raw token (32 url-safe bytes) exists exactly once, in the
  `{:ok, user, raw}` return — the row carries its SHA-256 hash alone
  (the MintPat posture). Delivery is best-effort AFTER the committed
  write: a failure of any shape logs and moves on — the user row is
  durable, and re-invite is the resend lever.
  """

  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Mailer

  require Logger

  @doc """
  Invites `address` (or re-invites its occupant). `opts` ride the write
  (e.g. `authorize?: false` for operator tooling); `deliver/2` is
  injectable. Returns the raw token — there is no way to recover it
  later.
  """
  @spec call(User.t() | nil, String.t(), function(), keyword()) ::
          {:ok, User.t(), String.t()} | {:error, :invalid_address | :already_active | term()}
  def call(actor, address, deliver \\ &Mailer.deliver_user_invitation/2, opts \\ []) do
    if UserEmail.valid_address?(address) do
      resolve_and_write(actor, address, deliver, opts)
    else
      {:error, :invalid_address}
    end
  end

  defp resolve_and_write(actor, address, deliver, opts) do
    case resolve_occupant(address) do
      {:ok, %User{} = occupant} ->
        occupant_write(occupant, address, deliver, actor, opts)

      :none ->
        create_invited(address, deliver, actor, opts)

      # coveralls-ignore-start - DB read failure mid-lookup: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The :already_active fork (:none and :accepted are both live
  # accounts — :accepted reaches here when the admin re-invites someone
  # who already accepted: their verified row resolves them).
  defp occupant_write(occupant, address, deliver, actor, opts) do
    if occupant.invite_state in [:none, :accepted] do
      {:error, :already_active}
    else
      reinvite(occupant, address, deliver, actor, opts)
    end
  end

  # Occupant resolution (#287) — ONE surface: any row on the address
  # resolves its owner (verified or reserved; unique_address keeps one
  # row per address, so one owner). System seam: authorize?: false —
  # the actor question is the admin write's, not this lookup's.
  # invite_state loads with the query, so the fork above never needs a
  # second fetch.
  defp resolve_occupant(address) do
    case row_owner(address) do
      {:ok, nil} ->
        :none

      {:ok, %User{} = user} ->
        {:ok, user}

      # coveralls-ignore-start - DB read failure mid-lookup: same class
      # as health's db_up? — not simulatable under the sandbox
      {:error, _read_failed} ->
        {:error, :occupant_lookup_failed}
        # coveralls-ignore-stop
    end
  end

  defp row_owner(address) do
    User
    |> Ash.Query.for_read(:get_by_address, %{email: address})
    |> Ash.Query.load(:invite_state)
    |> Ash.read_one(authorize?: false)
  end

  defp create_invited(address, deliver, actor, opts) do
    raw = mint_raw_token()
    hash = User.token_hash(raw)

    changeset =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:token_hash, hash)
      |> Ash.Changeset.for_create(:invite, %{email: address}, write_opts(actor, opts))

    case Ash.create(changeset) do
      {:ok, user} ->
        deliver_best_effort(address, raw, deliver)

        {:ok, with_live_state(user), raw}

      # coveralls-ignore-start - race-only: the occupant read above is
      # the sequential arbiter, so a create failure needs a commit in
      # the residual window (the unique_address race — the reservation
      # row rides the create) — true concurrency,
      # not sequential
      {:error, error} ->
        {:error, error}
        # coveralls-ignore-stop
    end
  end

  defp reinvite(user, address, deliver, actor, opts) do
    raw = mint_raw_token()
    hash = User.token_hash(raw)

    changeset =
      user
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:token_hash, hash)
      |> Ash.Changeset.for_update(:reinvite, %{}, write_opts(actor, opts))

    case Ash.update(changeset) do
      {:ok, user} ->
        deliver_best_effort(address, raw, deliver)

        {:ok, with_live_state(user), raw}

      # coveralls-ignore-start - race-only: a StaleRecord (the accepted
      # filter matching nothing) needs the acceptance to commit between
      # the occupant read and this write — true concurrency, not
      # sequential (a sequential accepted occupant routes to
      # :already_active above)
      {:error, error} ->
        {:error, error}
        # coveralls-ignore-stop
    end
  end

  # The admin path rides actor through opts (the RevokePat posture):
  # policies run by default — the caller's admin grant is the gate;
  # operator tooling passes authorize?: false in opts.
  defp write_opts(actor, opts) do
    Keyword.put(opts, :actor, actor)
  end

  # The return contract carries a LIVE invite_state (the admin surface
  # renders it): Ash does not recompute a loaded calculation on an
  # update result — a reinvited user would still answer :withdrawn from
  # its pre-write struct — and a fresh create has none loaded at all.
  # One load makes both arms tell the truth. authorize?: false — the
  # calc is display plumbing on a write the caller already cleared.
  defp with_live_state(user) do
    Ash.load!(user, :invite_state, authorize?: false)
  end

  # 32 url-safe random bytes — the MembershipInvite raw-token shape.
  defp mint_raw_token do
    random = :crypto.strong_rand_bytes(32)
    Base.url_encode64(random, padding: false)
  end

  # Best-effort delivery AFTER the committed write (the retired #478
  # invitation hook's posture): every failure shape — an {:error, _} result, a raise, an
  # exit, a throw — logs a warning and does NOT fail the invite. The
  # user row is durable; re-invite is the resend lever.
  defp deliver_best_effort(address, raw, deliver) do
    accept_url = Mailer.canonical_url("/invites/accept?token=" <> raw)
    outcome = try_delivery(deliver, address, accept_url)
    log_outcome(address, outcome)
  end

  defp try_delivery(deliver, address, accept_url) do
    deliver.(address, accept_url)
  rescue
    e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
  catch
    kind, value -> {:error, "#{kind}: #{inspect(value)}"}
  end

  defp log_outcome(_address, {:ok, _receipt}) do
    :ok
  end

  defp log_outcome(address, {:error, reason}) do
    Logger.warning(
      "invite email for #{address} failed to deliver (#{inspect(reason)}) - " <>
        "the account is created and invited; re-inviting is the resend lever"
    )
  end
end

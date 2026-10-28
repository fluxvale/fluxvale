defmodule FluxVale.Accounts.Operations.ProvisionPersonalOrg do
  @moduledoc """
  Provisions a personal Organization + owner Membership for a user (#119)
  and grants the welcome credits (#122): one commit carries org +
  membership + wallet + grant, or none of it.

  Idempotent: returns the existing org as `{:ok, org, false}` when the user
  already owns one — re-login never duplicates, and the probe returning
  before the create means the welcome grant never re-fires. On first call
  it creates the org and returns `{:ok, org, true}` — the `created?` flag
  is the caller-visible signal that provisioning (grant included) just ran.

  The org is named after the user's handle (owner-approved, #285): `name`
  is `user.username` and its `slug` is that same username, `-2`, `-3`…
  probed against org slugs on collision. The namespaces usually coincide —
  both derive from the same email local part in the same order — but
  diverge after renames or collisions, by design. The `unique_slug`
  identity stays the race arbiter: a lost JIT-signup race fails the create
  loudly instead of double-provisioning.

  System operation — runs with `authorize?: false`: the Membership create
  policy forbids actor-driven creation, and the JIT signup path has no actor
  to authorize anyway (the org must exist so that one can exist).
  """

  alias FluxVale.Accounts.Operations.PersonalOrgForUser
  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User

  # Bounded slug probing: exhausted only if the base plus every suffix up
  # to here is taken — a collision run no single username should produce.
  @max_slug_probes 100

  # #122: $3 of non-expiring credits (1 credit = 1 US cent, product.md).
  @welcome_grant_cents 300

  @spec call(User.t()) :: {:ok, Organization.t(), boolean()} | {:error, term()}
  def call(%User{} = user) do
    # The idempotency probe runs authorize?: false — system operation, the
    # signup path has no actor (see the moduledoc).
    case PersonalOrgForUser.call(user.id, authorize?: false) do
      {:ok, org} ->
        {:ok, org, false}

      :none ->
        # One atomic create: the org and its owner membership share the
        # action's transaction, so a membership failure rolls back the org
        # (no orphan orgs to poison the idempotency check).
        create_personal_org(user)
    end
  end

  defp create_personal_org(%User{username: nil}) do
    # The rolling-window straggler (NULL username) reaching the
    # docs/deployment.md operator heal: provisioning names the org after
    # the handle, so a bare Required :name/:slug error would name
    # nothing. One clear arm — the operator needs the straggler sweep,
    # not a changeset dump.
    {:error, :username_missing}
  end

  defp create_personal_org(%User{} = user) do
    outcome =
      Organization
      |> Ash.Changeset.for_create(:create, %{
        name: user.username,
        slug: unique_slug(user.username, 0)
      })
      |> Ash.Changeset.manage_relationship(:members, [user], type: :append, authorize?: false)
      |> Ash.Changeset.after_action(fn _changeset, org ->
        grant_welcome_credits(org)
      end)
      |> Ash.create(authorize?: false)

    case outcome do
      {:ok, org} ->
        {:ok, org, true}

      # defensive: a lost JIT-signup slug race (the probe picked a slug a
      # concurrent signer just took) fails the create here and rolls back
      # the signup — needs true concurrency to reach, so no sequential
      # test can; the identity index is the arbiter
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # #122: the welcome grant rides the org-create transaction — it exists
  # exactly when the org does (a lost JIT race rolls back with its grant,
  # and the idempotency probe never re-enters the create). Keyless per the
  # ledger's contract: a transactional post cannot retry, so once-per-org
  # holds without an idempotency key.
  defp grant_welcome_credits(%Organization{} = org) do
    case FluxVale.Billing.grant_credits(org, @welcome_grant_cents) do
      {:ok, _entry} ->
        {:ok, org}

      # defensive: a ledger-write failure fails the org create (and the
      # signup with it) — DB failure only, not sequential-test reachable
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # Pre-flight probe — the slug is picked free before the create, because
  # an identity conflict raised inside the caller's signup transaction
  # surfaces at the action boundary, past any local error handling. The
  # unique_slug identity remains the arbiter for a true concurrent race.
  defp unique_slug(base, attempt) when attempt < @max_slug_probes do
    slug = if attempt == 0, do: base, else: "#{base}-#{attempt + 1}"

    if slug_free?(slug), do: slug, else: unique_slug(base, attempt + 1)
  end

  defp unique_slug(base, _attempt) do
    # No real username exhausts the probe range; fall back to an
    # unguessable suffix rather than fail the signup.
    "#{base}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
  end

  defp slug_free?(slug) do
    # get? reads wrap NotFound inside Ash.Error.Invalid — treat any miss
    # (the only realistic outcome here) as free; a read failure falls out
    # as "free" and the create fails loudly instead (probe posture).
    case Organization.get_by_slug(slug, authorize?: false) do
      {:ok, _taken} ->
        false

      {:error, _not_found_or_failed} ->
        true
    end
  end
end

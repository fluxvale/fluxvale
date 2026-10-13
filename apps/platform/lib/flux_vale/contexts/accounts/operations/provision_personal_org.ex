defmodule FluxVale.Accounts.Operations.ProvisionPersonalOrg do
  @moduledoc """
  Provisions a personal Organization + owner Membership for a user (#119).

  Idempotent: returns the existing org as `{:ok, org, false}` when the user
  already owns one — re-login never duplicates. On first call it creates the
  org and returns `{:ok, org, true}`; the `created?` flag lets callers run
  one-time side effects (welcome credits, #122) exactly once.

  The org's `name` is the email's local part (display-only); its `slug` is
  the sanitized local part, `-2`, `-3`… probed on collision (v1 named orgs
  after `user.username`, which v2 users don't have). The `unique_slug`
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
  # to here is taken — a collision run no single local part should produce.
  @max_slug_probes 100

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

  defp create_personal_org(user) do
    outcome =
      Organization
      |> Ash.Changeset.for_create(:create, %{
        name: org_name(user),
        slug: unique_slug(base_slug(user), 0)
      })
      |> Ash.Changeset.manage_relationship(:members, [user], type: :append, authorize?: false)
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

  # Pre-flight probe — the slug is picked free before the create, because
  # an identity conflict raised inside the caller's signup transaction
  # surfaces at the action boundary, past any local error handling. The
  # unique_slug identity remains the arbiter for a true concurrent race.
  defp unique_slug(base, attempt) when attempt < @max_slug_probes do
    slug = if attempt == 0, do: base, else: "#{base}-#{attempt + 1}"

    if slug_free?(slug), do: slug, else: unique_slug(base, attempt + 1)
  end

  defp unique_slug(base, _attempt) do
    # No real local part exhausts the probe range; fall back to an
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

  defp org_name(user), do: local_part(user.email)

  defp base_slug(user) do
    slug =
      user.email
      |> local_part()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    # The slug validation needs 2+ chars; degenerate local parts ("+tag@…")
    # fall back to a neutral base that the suffix probe still uniquifies.
    if String.length(slug) < 2, do: "org", else: slug
  end

  defp local_part(email) do
    email
    |> to_string()
    |> String.split("@", parts: 2)
    |> List.first()
  end
end

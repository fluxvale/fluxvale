defmodule FluxVale.Identity.User.DeriveUsername do
  @moduledoc """
  Derives the username from the email at signup (#285 T2) — the
  ProvisionPersonalOrg slug pattern applied to usernames: sanitize the
  local part, probe `-2`, `-3`… on collision, bounded probes then an
  unguessable random suffix.

  A username already on the changeset is kept, but derivation is the
  only writer in this slice (no input surface, no format validation;
  both arrive with the rename UI). Signup must never fail on derivation
  (the #279 lesson): every produced value satisfies
  `[a-z0-9][a-z0-9-]*[a-z0-9]` at 2–39 chars — long local parts
  truncate, they do not break the signup. Wired before
  ProvisionPersonalOrg, which must see the username.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.User

  # Bounded probing, matching ProvisionPersonalOrg's slug probe.
  @max_probes 100

  # Derived usernames never land bare on these — `admin@…` signs up as
  # `admin-2`.
  @reserved ~w(admin fluxvale support root org organization billing api www mail security help)

  @fallback_base "user"
  @max_length 39
  @min_length 2

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :username) do
      nil ->
        email = Ash.Changeset.get_attribute(changeset, :email)
        Ash.Changeset.change_attribute(changeset, :username, derive_unique(email))

      _already_set ->
        changeset
    end
  end

  @doc """
  The derive+probe core, shared with the `backfill_usernames` migration —
  one algorithm, no forked copy. `free?/1` decides whether a candidate
  is claimable; the default probes the users table through
  `get_by_username`. The migration must inject a raw-SQL closure
  instead: an Ash read SELECTs every current User attribute, so it
  would break fresh-DB replay the moment the resource outgrows the
  frozen migration (ADR-00013's undefined-column class).
  """
  @spec derive_unique(String.Chars.t(), (String.t() -> boolean())) :: String.t()
  def derive_unique(email, free? \\ &default_free?/1) do
    derived = base(email)
    unique(derived, 0, free?)
  end

  # Sanitize the local part, truncate to 39, re-trim the hyphen the cut
  # can expose, and fall back to the neutral base when too little
  # survives ("+@…" sanitizes to nothing).
  defp base(email) do
    sanitized =
      email
      |> to_string()
      |> local_part()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    truncated = String.slice(sanitized, 0, @max_length)
    trimmed = String.trim(truncated, "-")

    if String.length(trimmed) < @min_length, do: @fallback_base, else: trimmed
  end

  defp local_part(email) do
    email
    |> to_string()
    |> String.split("@", parts: 2)
    |> List.first()
  end

  # Probe posture mirrors ProvisionPersonalOrg's slug probe: the read
  # runs authorize?: false (system operation — the signup path has no
  # actor); a read failure falls out as "free" and the create fails
  # loudly instead, with the identity index as the race arbiter. A
  # same-local-part concurrent signup therefore burns its email code and
  # dies in the catch-all flash — provisioning's identical posture (its
  # org-slug race). Revisit trigger: retry-in-transaction or an advisory
  # lock when usernames become load-bearing public handles (the
  # switcher slice).
  defp unique(base, attempt, free?) when attempt < @max_probes do
    suffix = if attempt == 0, do: "", else: "-#{attempt + 1}"
    proposed = with_suffix(base, suffix)

    if taken?(proposed, free?), do: unique(base, attempt + 1, free?), else: proposed
  end

  defp unique(base, _attempt, _free?) do
    # No real local part exhausts the probe range; fall back to an
    # unguessable suffix rather than fail the signup (provisioning's
    # exact fallback shape).
    random_bytes = :crypto.strong_rand_bytes(4)
    random_hex = Base.encode16(random_bytes, case: :lower)
    random_suffix = "-" <> random_hex
    with_suffix(base, random_suffix)
  end

  # The suffix eats into the base's budget so the whole name stays
  # within the 2–39 contract; a shorter cut can expose a trailing
  # hyphen, which is re-trimmed.
  defp with_suffix(base, suffix) do
    budget = @max_length - String.length(suffix)
    shortened = String.slice(base, 0, budget)
    trimmed = String.trim(shortened, "-")

    trimmed <> suffix
  end

  defp taken?(proposed, free?) do
    reserved?(proposed) or not free?.(proposed)
  end

  defp reserved?(proposed), do: proposed in @reserved

  # System path — the signup probe runs authorize?: false (no actor on
  # the JIT path).
  defp default_free?(candidate) do
    # get? reads wrap NotFound inside Ash.Error.Invalid — treat any miss
    # (the only realistic outcome here) as free.
    case User.get_by_username(candidate, authorize?: false) do
      {:ok, _taken} -> false
      {:error, _not_found_or_failed} -> true
    end
  end
end

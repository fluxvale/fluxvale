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
  one algorithm, no forked copy. Probes the users table through
  `get_by_username`, so the Repo must be running.
  """
  @spec derive_unique(String.Chars.t()) :: String.t()
  def derive_unique(email) do
    derived = base(email)
    unique(derived, 0)
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
  # loudly instead, with the identity index as the race arbiter.
  defp unique(base, attempt) when attempt < @max_probes do
    suffix = if attempt == 0, do: "", else: "-#{attempt + 1}"
    proposed = with_suffix(base, suffix)

    if taken?(proposed), do: unique(base, attempt + 1), else: proposed
  end

  defp unique(base, _attempt) do
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

  defp taken?(proposed) do
    reserved?(proposed) or not free?(proposed)
  end

  defp reserved?(proposed), do: proposed in @reserved

  defp free?(proposed) do
    # get? reads wrap NotFound inside Ash.Error.Invalid — treat any miss
    # (the only realistic outcome here) as free.
    case User.get_by_username(proposed, authorize?: false) do
      {:ok, _taken} -> false
      {:error, _not_found_or_failed} -> true
    end
  end
end

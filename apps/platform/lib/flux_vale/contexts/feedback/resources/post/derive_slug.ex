defmodule FluxVale.Feedback.Post.DeriveSlug do
  @moduledoc """
  Derives the public URL slug from the title at create — the
  DeriveUsername pattern (#285): sanitize, probe `-2`, `-3`… on
  collision, bounded probes then an unguessable random suffix. Set at
  create only: no later action writes it (URLs are sticky, ADR-0026 §4).

  Three carve-outs, stated honestly:

  - Reserved stems (`@reserved`, day-one: `new`) keep fixed routes
    under /feedback claimable — /feedback/new must never be a post.
    Revisit trigger: the day a fixed route joins /feedback, its segment
    joins the list.
  - The exhaustion fallback's random suffix is UNGUESSABLE, not unique —
    the `unique_slug` identity index stays the arbiter of last resort.
  - The probe read RAISES on failure: a create dies loudly rather than
    planting a possibly-taken slug. A different, louder posture than
    DeriveUsername's treat-read-failure-as-free — chosen because a
    public URL stem that collides silently is worse than a failed
    admin click.

  The probe reads `authorize?: false` — a uniqueness check is a write
  concern, not an exposure (the EnsureRegistrable stance), and it runs
  in the create transaction (a before_action), so probe and insert see
  one consistent table.
  """

  use Ash.Resource.Change

  alias FluxVale.Feedback.Post

  require Ash.Query

  @max_probes 100
  @max_length 140
  @fallback_base "post"
  @min_length 2

  # Stems a post slug must never claim — fixed routes under /feedback
  # would be shadowed. Revisit trigger: the day a fixed route joins
  # /feedback, its segment joins this list.
  @reserved ~w(new)

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # The guard lives INSIDE the hook, at write time: a slug forced onto
    # the changeset after for_create returns (a seed/bulk path) must not
    # be clobbered by the derivation either.
    Ash.Changeset.before_action(changeset, &derive_if_absent/1)
  end

  defp derive_if_absent(changeset) do
    # slug is never accepted — derivation is the only writer.
    case Ash.Changeset.get_attribute(changeset, :slug) do
      nil ->
        title = Ash.Changeset.get_attribute(changeset, :title)
        Ash.Changeset.force_change_attribute(changeset, :slug, derive_unique(title))

      _already_set ->
        changeset
    end
  end

  @doc """
  The derive+probe core, public so tests can exhaust the probe range
  without 100 colliding rows (the DeriveUsername shape). `free?/1`
  decides whether a candidate is claimable; the default probes the
  feedback_posts table.
  """
  @spec derive_unique(String.t(), (String.t() -> boolean())) :: String.t()
  def derive_unique(title, free? \\ &default_free?/1) do
    derived = base(title)
    unique(derived, 0, free?)
  end

  # The shared sanitize RULES: downcase, non-alphanumerics collapse to
  # hyphens, hyphen edges trimmed. Public because the tag vocabulary
  # derives with the same rules (Tag.DeriveSlug, T10) — one rule, two
  # readers, so the URL shapes cannot fork.
  @spec sanitize(String.t()) :: String.t()
  def sanitize(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Sanitize the title, truncate to 140, re-trim the hyphen the cut can
  # expose, and fall back to the neutral base when too little survives
  # (a 4-char all-punctuation title sanitizes to nothing).
  defp base(title) do
    sanitized = sanitize(title)
    truncated = String.slice(sanitized, 0, @max_length)
    trimmed = String.trim(truncated, "-")

    if String.length(trimmed) < @min_length, do: @fallback_base, else: trimmed
  end

  defp unique(base, attempt, free?)

  defp unique(base, attempt, free?) when attempt < @max_probes do
    suffix = if attempt == 0, do: "", else: "-#{attempt + 1}"
    proposed = with_suffix(base, suffix)

    if claimable?(proposed, free?), do: proposed, else: unique(base, attempt + 1, free?)
  end

  defp unique(base, _attempt, _free?) do
    # No real title exhausts the probe range; fall back to an
    # unguessable suffix rather than fail the create (DeriveUsername's
    # exact fallback shape).
    random_bytes = :crypto.strong_rand_bytes(4)
    random_hex = Base.encode16(random_bytes, case: :lower)
    with_suffix(base, "-#{random_hex}")
  end

  # The suffix eats into the base's budget so the whole slug stays
  # within the 140 contract; a shorter cut can expose a trailing
  # hyphen, which is re-trimmed.
  defp with_suffix(base, suffix) do
    budget = @max_length - String.length(suffix)
    shortened = String.slice(base, 0, budget)
    "#{String.trim(shortened, "-")}#{suffix}"
  end

  # A stem is claimable when it is neither reserved nor taken. The probe
  # read raises on failure — see the moduledoc's posture carve-out.
  defp claimable?(proposed, free?) do
    not reserved?(proposed) and free?.(proposed)
  end

  defp reserved?(proposed), do: proposed in @reserved

  # The uniqueness probe reads authorize?: false — a write concern, not
  # an exposure (the EnsureRegistrable stance).
  defp default_free?(candidate) do
    taken =
      Post
      |> Ash.Query.filter(slug == ^candidate)
      |> Ash.exists?(authorize?: false)

    not taken
  end

  @impl Ash.Resource.Change
  def atomic?, do: false
end

defmodule FluxVale.Catalog.AppVersion.SetSortKey do
  @moduledoc """
  The version grammar and its sort key (#700): `list_for_app` orders
  by `sort_key`, never the `version` string — string order is not
  semver ("9.2.0" > "10.0.0" and "3.4.1-bundled" > "3.4.1" as
  strings, both wrong for newest-first).

  - **Grammar** — evidence: every shipped version string (X.Y.Z
    triples, plus umami's `-bundled` packaging variant):
    `major.minor.patch` with 1..6 ASCII digits per segment, then
    optionally ONE `-suffix` of `[0-9a-z]+`. Nothing else: no `v`
    prefix, no `1.2` two-segment shape, no `+build` metadata, no
    uppercase or punctuation in the suffix — the restricted suffix
    alphabet is what keeps SQL and Elixir ordering identical (see
    Encoding). Enforced on the action path by the `version`
    attribute's `match` constraint (`pattern/0` is the one regex);
    `Ash.Seed.seed!` bypasses actions, so test seeds hand-stamp their
    key alongside the version.
  - **Order** — a semver 2.0.0 subset: segments compare numerically;
    a suffixed version sorts BELOW its bare release (the pre-release
    rule — `3.4.1-bundled` < `3.4.1`, #700's expected order);
    suffixes compare as plain strings. Semver's dot-numeric
    identifier rule is deliberately not implemented — the restricted
    alphabet admits no dots; the first suffix that needs one reopens
    this.
  - **Encoding** — segments zero-padded to 6 and dot-joined, then
    `.1` for a release or `.0` + the suffix. Lexicographic order on
    the key IS semantic order, in Elixir and in SQL alike: digits
    decide the numeric bands identically in every collation (the rank
    digit keeps a release above its suffixes; a punctuation trick
    like `~`-above-`-` silently inverts under `en_US.UTF-8`), and the
    `[0-9a-z]` suffix alphabet collates identically to byte order.
    SQL `sort_key DESC` is newest-first.
  - **Caveats** — a 7-digit segment (none upstream) would overflow
    the band; a suffix needing dots, hyphens, or uppercase forces
    either a key change or a `COLLATE "C"` pin on the column. Both
    are write-rejected today; revisit when a real version ships one.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  # \A…\z (never ^…$): the line anchors match before a trailing
  # newline. Actions never see one (Ash.Type.String trims at cast);
  # this guards the direct key/1 callers — test seeds and the
  # migration backfill (CodeRabbit, #703).
  @grammar ~r/\A(\d{1,6})\.(\d{1,6})\.(\d{1,6})(-[0-9a-z]+)?\z/

  @doc """
  The grammar as a `match` constraint pattern — the `version`
  attribute rejects anything outside it at write time.
  """
  @spec pattern() :: Regex.t()
  def pattern, do: @grammar

  @doc """
  The sortable key for a conforming version string (the migration's
  backfill calls this too, so the encoding has one home). Raises on
  anything outside the grammar — the action path can't get there
  (the constraint rejects it first), so the raise is the belt behind
  the suspenders.
  """
  @spec key(String.t()) :: String.t()
  def key(version) do
    case Regex.run(@grammar, version) do
      [_full, major, minor, patch] -> triple(major, minor, patch) <> ".1"
      [_full, major, minor, patch, suffix] -> triple(major, minor, patch) <> ".0" <> suffix
      nil -> raise ArgumentError, "version #{inspect(version)} is outside the catalog grammar"
    end
  end

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # version is immutable after create (the seed lookup key), so the
    # key is written once here — there is no update path to keep in
    # step. nil = the grammar constraint already rejected the input
    # (a failed cast drops the attribute); this change still runs on
    # the invalid changeset, so leave the key unset and let that error
    # surface.
    version = Changeset.get_attribute(changeset, :version)

    if version do
      Changeset.change_attribute(changeset, :sort_key, key(version))
    else
      changeset
    end
  end

  defp triple(major, minor, patch) do
    pad(major) <> "." <> pad(minor) <> "." <> pad(patch)
  end

  defp pad(segment), do: String.pad_leading(segment, 6, "0")
end

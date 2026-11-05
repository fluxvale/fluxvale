defmodule FluxVale.Feedback.Tag.DeriveSlug do
  @moduledoc """
  Derives the tag's slug from its name when the create does not author
  one. The sanitize RULES are Post.DeriveSlug's (shared, public — one
  rule, two readers, so the URL shapes cannot fork); the collision
  posture is NOT: no `-2` probing. The vocabulary is admin-curated with
  a handful of writes ever, so a slug collision is operator error that
  must fail the create loudly (the `unique_slug` identity is the
  arbiter) — not silently mint an unrequested stem.
  """

  use Ash.Resource.Change

  alias FluxVale.Feedback.Post

  # Tag slugs cap at 50 (the attribute's constraint): truncate the
  # sanitized name and re-trim the hyphen the cut can expose.
  @max_length 50

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # The guard lives INSIDE the hook, at write time (the Post.DeriveSlug
    # shape): a slug forced onto the changeset after for_create returns
    # (the seed's get-or-create) must not be clobbered by the derivation.
    Ash.Changeset.before_action(changeset, &derive_if_absent/1)
  end

  defp derive_if_absent(changeset) do
    # slug is authored or derived — never both.
    case Ash.Changeset.get_attribute(changeset, :slug) do
      nil ->
        name = Ash.Changeset.get_attribute(changeset, :name)
        Ash.Changeset.force_change_attribute(changeset, :slug, derive(name))

      _already_set ->
        changeset
    end
  end

  defp derive(name) do
    name
    |> Post.DeriveSlug.sanitize()
    |> String.slice(0, @max_length)
    |> String.trim("-")
  end

  # A function change (the before_action hook) — Ash cannot run it
  # atomically; a single-row admin write, the trade Post's :set_status
  # makes.
  @impl Ash.Resource.Change
  def atomic?, do: false
end

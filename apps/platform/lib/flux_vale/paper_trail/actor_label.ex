defmodule FluxVale.PaperTrail.ActorLabel do
  @moduledoc """
  Version-resource change: denormalize the acting user's label onto the
  version row (#645, the plan's D6 tombstone probe).

  `belongs_to_actor`'s `on_delete: :nilify` keeps the history when a
  user is deleted but drops the pointer — `actor_label` is the
  write-time `username` snapshot that still answers WHO. Users are the
  only actor kind in v1; a system (actorless) write records nil, the
  same honest shape as the actor reference itself. Revisit trigger: a
  second actor kind appears — grow the label here, one module.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # The actor rides the version changeset's private context — the
    # same key ash_paper_trail's own actor wiring reads (always set on
    # Version create, per its docs).
    actor = get_in(changeset.context, [:private, :actor])

    Ash.Changeset.change_attribute(changeset, :actor_label, label(actor))
  end

  defp label(%FluxVale.Identity.User{username: username}), do: username
  defp label(_system_or_unknown), do: nil
end

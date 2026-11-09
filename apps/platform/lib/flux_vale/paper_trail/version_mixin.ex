defmodule FluxVale.PaperTrail.VersionMixin do
  @moduledoc """
  The shared recipe mixed into every ash_paper_trail version resource
  (#645, ADR-0048): the audit view's indexes and the actor-label
  tombstone. Each versioned resource references it verbatim —
  `mixin {FluxVale.PaperTrail.VersionMixin, :version_resource, []}` —
  so the version-table posture cannot drift as later slices roll the
  trail out over the business set.
  """

  @doc """
  The code mixed into a generated version resource (the dep's `mixin`
  MFA shape): `version_source_id` / `user_id` indexes for the audit
  view's two axes, plus the `actor_label` attribute `ActorLabel` stamps
  on create. Attribute names are the generated ones, confirmed against
  the 0.8.1 codegen output.
  """
  @spec version_resource() :: Macro.t()
  def version_resource do
    quote do
      postgres do
        custom_indexes do
          # The audit view's two axes: one record's history, one
          # actor's.
          index([:version_source_id])
          index([:user_id])
        end
      end

      attributes do
        attribute :actor_label, :string do
          public?(true)
        end
      end

      changes do
        change(FluxVale.PaperTrail.ActorLabel, on: :create)
      end
    end
  end
end

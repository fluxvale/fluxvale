defmodule FluxVale.PaperTrail.VersionMixin do
  @moduledoc """
  The shared recipe mixed into every ash_paper_trail version resource
  (#645, ADR-0048): the direct admin-only read policy, the audit view's
  indexes, and the actor-label tombstone. Each versioned resource
  references it verbatim —
  `mixin {FluxVale.PaperTrail.VersionMixin, :version_resource, []}` —
  so the version-table posture cannot drift as later slices roll the
  trail out over the business set. The line is mandatory, not optional:
  a resource omitting it ships policy-less version tables.
  """

  # Compile-time-only — the ash_paper_trail transformer consumes this
  # quote while building each Version resource, so the body never runs
  # at test time. What it shapes (the version tables, policy, indexes,
  # actor label) is exercised end to end in
  # test/flux_vale/contexts/ops/paper_trail_test.exs. If the mixin ever
  # grows runtime behavior, a real test wins and this block goes.
  # coveralls-ignore-start
  @doc """
  The code mixed into a generated version resource (the dep's `mixin`
  MFA shape): the direct admin-only read policy (D7, revised), the
  audit view's indexes (`version_source_id`, `user_id`,
  `version_inserted_at` + `id`, `actor_label`), and the
  `actor_label` attribute `ActorLabel` stamps on create. Attribute
  names are the generated ones, confirmed against the 0.8.1 codegen
  output. The Policy authorizer itself attaches via the posture's
  `version_extensions` line on the source resource — the doctrine
  gate pins that line alongside the mixin, the authorizer without
  policies denies nothing.
  """
  @spec version_resource() :: Macro.t()
  def version_resource do
    quote do
      policies do
        # D7 (revised on hostile-review evidence): a DIRECT admin-only
        # gate, not source-policy replay — replay would admit whoever
        # can read the source (anonymous, once public-read sources
        # version) and filters out destroyed-source rows for everyone.
        policy always() do
          description("Platform admins read version history (#645)")

          authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
        end
      end

      postgres do
        custom_indexes do
          # The audit view's four axes: one record's history, one
          # actor's user_id, the newest-first sort (the stamp with the
          # id as the tiebreaker), and the tombstone-label match the
          # actor filter reads.
          index([:version_source_id])
          index([:user_id])
          index([:version_inserted_at, :id])
          index([:actor_label])
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

  # coveralls-ignore-stop
end

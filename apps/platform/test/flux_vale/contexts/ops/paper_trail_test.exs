defmodule FluxVale.Ops.PaperTrailTest do
  @moduledoc false

  # The audit-trail proof on Ops (#645, the plan's A2-S1 slice): every
  # mutation on FeatureFlag writes an attributed, surviving, honest
  # version row, and version reads hold the repo's authorization-on
  # discipline. AccessRule carries the same posture — one resource is
  # the proof, the other confirms the shared mixin and codegen hold
  # for both tables. Version-row reads that assert STORAGE (not
  # authorization) run authorize?: false; the D7 arms read through
  # policies.

  use FluxVale.DataCase, async: true

  alias AshPaperTrail.Resource.Info
  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.FeatureFlag

  require Ash.Query

  # Preconditions run authorize?: false (repo convention — mirrors the
  # seeds bootstrap); the version-read policies are what's under test
  # in the D7 describe block below.
  defp admin do
    case User.get_by_email("paper-trail-admin@fluxvale.com", authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!("paper-trail-admin@fluxvale.com", %{platform_role: :admin},
          authorize?: false
        )
    end
  end

  defp member do
    User.create!("paper-trail-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp create_flag!(params, opts) do
    base = %{
      key: "pt_#{System.unique_integer([:positive])}",
      enabled: true,
      description: "trail proof"
    }

    FeatureFlag
    |> Ash.Changeset.for_create(:create, Map.merge(base, params), opts)
    |> Ash.create!()
  end

  defp versions!(source_id) do
    FeatureFlag.Version
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.read!(authorize?: false)
  end

  describe "every mutation leaves evidence" do
    test "a create writes an attributed version row with action, inputs, and changes" do
      admin = admin()

      flag = create_flag!(%{}, actor: admin)
      [version] = versions!(flag.id)

      assert version.version_action_type == :create
      assert version.version_action_name == :create
      assert version.version_action_inputs["key"] == flag.key
      assert version.version_action_inputs["enabled"] == true
      assert version.changes["key"] == flag.key
      assert version.changes["enabled"] == true
      assert version.version_source_id == flag.id
      refute is_nil(version.operation_id)
      assert version.user_id == admin.id
      assert version.actor_label == admin.username
    end

    test "an update versions only the changed attributes" do
      admin = admin()
      flag = create_flag!(%{}, actor: admin)

      flag
      |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: admin)
      |> Ash.update!()

      [create_version, update_version] =
        FeatureFlag.Version
        |> Ash.Query.filter(version_source_id == ^flag.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      assert create_version.version_action_type == :create
      assert update_version.version_action_type == :update
      assert update_version.version_action_name == :update
      # changes_only: just the diff, not a snapshot (D6)
      assert update_version.changes == %{"enabled" => false}
      assert update_version.user_id == admin.id
    end

    test "an empty update (nothing submitted) writes no version (only_when_changed?)" do
      admin = admin()
      flag = create_flag!(%{}, actor: admin)

      _updated =
        flag
        |> Ash.Changeset.for_update(:update, %{}, actor: admin)
        |> Ash.update!()

      assert length(versions!(flag.id)) == 1
    end

    test "an identical-value resubmission still versions — Ash's changed? is changeset-shaped, not value-shaped" do
      # Upstream 0.8.1 semantics, pinned: `context.changed?` means the
      # changeset CARRIES changes, so resubmitting the same values
      # writes a row. Disclosed in the ADR's probe notes, not doctrine.
      admin = admin()
      flag = create_flag!(%{}, actor: admin)

      updated =
        flag
        |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: admin)
        |> Ash.update!()

      _resubmitted =
        updated
        |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: admin)
        |> Ash.update!()

      # create + first update + the resubmission's extra row
      assert length(versions!(updated.id)) == 3
    end

    test "a destroy's version row survives the record's own deletion" do
      # reference_source? false: no FK from the version table to the
      # source, so the destroy's evidence outlives the row it
      # describes — the doctrine's audit-grade property (D6). The
      # destroy row itself carries no changes (:changes_only has no
      # deltas on destroy): the final state reconstructs by replaying
      # the record's chain; this row answers who/what/when.
      admin = admin()
      flag = create_flag!(%{}, actor: admin)

      Ash.destroy!(flag, actor: admin)

      survivors = versions!(flag.id)
      surviving_types = MapSet.new(survivors, & &1.version_action_type)

      assert MapSet.equal?(surviving_types, MapSet.new([:create, :destroy]))

      destroy_version = Enum.find(survivors, &(&1.version_action_type == :destroy))
      assert destroy_version.changes == %{}
      assert destroy_version.user_id == admin.id

      # and the source row is really gone
      assert FeatureFlag
             |> Ash.Query.filter(id == ^flag.id)
             |> Ash.read!(authorize?: false) == []

      # the orphaned evidence stays readable through POLICIES by an
      # admin (the direct read policy — no exists() over a gone row)
      admin_rows =
        FeatureFlag.Version
        |> Ash.Query.filter(version_source_id == ^flag.id)
        |> Ash.read!(actor: admin)

      assert MapSet.new(admin_rows, & &1.version_action_type) ==
               MapSet.new([:create, :destroy])
    end
  end

  describe "attribution (who made the write)" do
    test "a member-actor write names that user" do
      member = member()

      # Ops writes are admin-only (ADR-0030), so this arm rides
      # authorize?: false with the actor set: attribution is under
      # test, not authorization (no member-writable Ops resource
      # exists).
      flag = create_flag!(%{}, authorize?: false, actor: member)
      [version] = versions!(flag.id)

      assert version.user_id == member.id
      assert version.actor_label == member.username
    end

    test "a system write records the honest nil actor" do
      # authorize?: false, no actor — the seeds/Oban/webhook shape.
      flag = create_flag!(%{}, authorize?: false)
      [version] = versions!(flag.id)

      assert is_nil(version.user_id)
      assert is_nil(version.actor_label)
    end
  end

  describe "version reads (D7 revised: direct admin-only policy on the mixin)" do
    setup do
      %{flag: create_flag!(%{}, actor: admin())}
    end

    test "an admin reads version history through policies", %{flag: flag} do
      admin = admin()

      rows =
        FeatureFlag.Version
        |> Ash.Query.filter(version_source_id == ^flag.id)
        |> Ash.read!(actor: admin)

      assert length(rows) == 1
    end

    test "a member's version read is Forbidden", %{flag: _flag} do
      member = member()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(FeatureFlag.Version, actor: member)
    end

    test "an anonymous version read is Forbidden — the trail is never public", %{flag: _flag} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(FeatureFlag.Version, actor: nil)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(FeatureFlag.Version)
    end
  end

  describe "the second table (AccessRule carries the same posture)" do
    test "an AccessRule create writes an attributed version row" do
      admin = admin()

      rule =
        AccessRule.create!(
          %{domain: "pt-#{System.unique_integer([:positive])}.example"},
          actor: admin
        )

      [version] =
        AccessRule.Version
        |> Ash.Query.filter(version_source_id == ^rule.id)
        |> Ash.read!(authorize?: false)

      assert version.version_action_type == :create
      assert version.user_id == admin.id
      assert version.actor_label == admin.username
    end
  end

  describe "the sensitive posture" do
    test "redaction is configured on both resources (the blanket posture)" do
      # Ops carries no sensitive attributes or arguments — the sweep's
      # sensitive carriers (MembershipInvite, PersonalAccessToken)
      # version in later slices and will exercise the :redact arm
      # there. What this slice pins is the posture itself: one uniform
      # config block, no per-resource tuning.
      assert Info.sensitive_attributes(FeatureFlag) == :redact
      assert Info.sensitive_attributes(AccessRule) == :redact
    end
  end
end

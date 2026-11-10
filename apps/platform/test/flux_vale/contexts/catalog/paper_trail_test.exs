defmodule FluxVale.Catalog.PaperTrailTest do
  @moduledoc false

  # The audit-trail proof on Catalog (#645, the plan's A2-S2 slice):
  # the deploy blueprint's composite attrs (the env-var schema)
  # serialize JSON-safe into the version row, and the identical-value
  # resubmission posture is pinned for THIS domain's action flavor.
  # Mirrors the Ops suite (the A2-S1 exemplar): version-row reads that
  # assert STORAGE run authorize?: false; the D7 version-read policy is
  # pinned there.

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  defp versions!(source_id) do
    AppVersion.Version
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  # The seed-shaped preconditions (actions, authorize?: false — the
  # bootstrap posture): category, app, and the recommended size the
  # blueprint's allocation validation requires.
  defp blueprint! do
    n = System.unique_integer([:positive])

    category =
      Category
      |> Ash.Changeset.for_create(:create, %{name: "Trail #{n}", slug: "trail-#{n}"},
        authorize?: false
      )
      |> Ash.create!()

    app =
      App
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Trail App #{n}", slug: "trail-app-#{n}", category_id: category.id},
        authorize?: false
      )
      |> Ash.create!()

    size =
      Size
      |> Ash.Changeset.for_create(
        :create,
        %{
          slug: "trail-#{n}",
          cpu_cores: Decimal.new("1.0"),
          memory_mb: 1024,
          monthly_cents: 500
        },
        authorize?: false
      )
      |> Ash.create!()

    {app, size}
  end

  defp app_version!(app, size, admin, params \\ %{}) do
    base = %{
      version: "1.0.0",
      image: "trail:1",
      port: 8080,
      app_id: app.id,
      recommended_size_id: size.id,
      default_cpu_cores: Decimal.new("1.0"),
      default_memory_mb: 1024,
      default_storage_gb: 0,
      configurable_env_vars: %{
        "DB_HOST" => %{label: "DB host", type: :string, default: "localhost", required: true}
      }
    }

    AppVersion
    |> Ash.Changeset.for_create(:create, Map.merge(base, params), actor: admin)
    |> Ash.create!()
  end

  describe "the composite blueprint attrs" do
    test "an AppVersion create versions the env-var schema as JSON-safe maps" do
      admin = AccountsFixtures.admin!()
      {app, size} = blueprint!()

      av = app_version!(app, size, admin)

      [version] = versions!(av.id)

      assert version.version_action_type == :create
      assert version.version_action_name == :create
      assert version.user_id == admin.id
      assert version.actor_label == admin.username

      # The EnvVarSchema storage round-trip: string keys and plain inner
      # maps — atoms and structs do not survive it, so the version row
      # is JSON-safe by construction.
      assert version.changes["configurable_env_vars"] == %{
               "DB_HOST" => %{
                 "default" => "localhost",
                 "label" => "DB host",
                 "required" => true,
                 "secret" => false,
                 "type" => "string"
               }
             }

      # The #651-disclosed inputs quirk, pinned as observed: the composite
      # attr's stored INPUTS keep the env-var names but empty each inner
      # spec. The changes map above is the lossless record; inputs are
      # the arguments-of-record.
      assert version.version_action_inputs["configurable_env_vars"] == %{"DB_HOST" => %{}}
    end

    test "an identical-value resubmission on the non-atomic update writes no extra version" do
      # Pinned as observed, the complement of the Ops suite's quirk:
      # every Catalog update carries require_atomic?(false) (the
      # transactional validations' documented trade), so Ash drops the
      # no-op change and only_when_changed? keeps the trail quiet. The
      # extra-row quirk manifests only on atomic-capable actions —
      # pinned on TaxRate in the Pricing suite.
      admin = AccountsFixtures.admin!()
      {app, size} = blueprint!()

      av = app_version!(app, size, admin)
      assert length(versions!(av.id)) == 1

      updated =
        av
        |> Ash.Changeset.for_update(:update, %{release_notes: "notes"}, actor: admin)
        |> Ash.update!()

      _resubmitted =
        updated
        |> Ash.Changeset.for_update(:update, %{release_notes: "notes"}, actor: admin)
        |> Ash.update!()

      # create + the first update's real change (nil -> "notes"); the
      # resubmission is a no-op and versions nothing.
      assert length(versions!(av.id)) == 2
    end
  end
end

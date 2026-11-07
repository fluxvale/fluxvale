defmodule FluxValeWeb.AdminVersionEditLiveTest do
  @moduledoc false

  # The version edit form (#501): blueprint and envelope together, the
  # coherence rule stated up front, a mismatch explained before any
  # submit, and first-run contract edits riding the key-ownership
  # validation. BOTH guards are pinned: surfaced pre-write through the
  # form AND still enforced at the action level (crafted direct writes
  # fail).

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.PricingFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-version-edit-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin)}
  end

  describe "mount" do
    test "states the rule and shows the current truth", %{conn: conn} do
      version = built_version!()

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      # The coherence rule, up front.
      assert has_element?(
               view,
               "[data-testid='admin-version-coherence-rule']",
               "must describe the same allocation"
             )

      # The current size is the selected option.
      assert has_element?(
               view,
               "[data-testid='admin-version-size-select'] option[value='#{version.recommended_size_id}'][selected]"
             )

      # The defaults are the record's own values (cpu is a Decimal, so
      # the input takes its string form).
      assert has_element?(view, "[data-testid='admin-version-cpu'][value='0.5']")
      assert has_element?(view, "[data-testid='admin-version-memory'][value='256']")

      # A contract-less version reads "No contract", not a blank.
      assert has_element?(
               view,
               "[data-testid='admin-version-firstrun-pattern'] option[value=''][selected]"
             )
    end

    test "an unknown version reads as not editable here", %{conn: conn} do
      missing_id = "00000000-0000-0000-0000-000000000000"

      assert {:error, {:live_redirect, %{flash: flash, to: "/admin/catalog"}}} =
               live(conn, "/admin/catalog/versions/#{missing_id}")

      assert flash["error"] == "That version is not editable here."
    end
  end

  describe "the coherence rule, surfaced pre-write" do
    test "a defaults edit that drifts from the size explains itself on change", %{conn: conn} do
      version = built_version!()

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      render_change(view, "validate", %{
        "app_version" => %{
          "recommended_size_id" => version.recommended_size_id,
          "default_memory_mb" => "4096"
        }
      })

      assert has_element?(
               view,
               "[data-testid='admin-version-coherence-mismatch']",
               "This save will not pass"
             )

      assert has_element?(
               view,
               "[data-testid='admin-version-coherence-mismatch']",
               "provides 0.5 CPU, 256 MB, 0 GB"
             )
    end

    test "a coherent edit shows no mismatch", %{conn: conn} do
      version = built_version!()

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      render_change(view, "validate", %{
        "app_version" => %{
          "recommended_size_id" => version.recommended_size_id,
          "default_memory_mb" => "256"
        }
      })

      refute has_element?(view, "[data-testid='admin-version-coherence-mismatch']")
    end

    test "garbage reads as no opinion on coherence (the field errors tell that story)", %{
      conn: conn
    } do
      version = built_version!()

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      # A cpu value no Decimal parses, and a size id nothing selected:
      # the mismatch read has nothing to say, no crash.
      render_change(view, "validate", %{
        "app_version" => %{
          "recommended_size_id" => "00000000-0000-0000-0000-000000000000",
          "default_cpu_cores" => "abc"
        }
      })

      refute has_element?(view, "[data-testid='admin-version-coherence-mismatch']")
    end
  end

  describe "saving" do
    # A defaults-only edit cannot be coherent by design — the defaults
    # must equal the size's allocation, so defaults can only move with
    # the size (the re-point tests below). The plain-save arm is a
    # no-change save: it runs the update action through the policies
    # and lands as a no-op.
    test "a coherent save runs the action with the admin actor", %{conn: conn} do
      version = built_version!()

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      params = app_version_params(version)
      render_change(view, "validate", %{"app_version" => params})
      refute has_element?(view, "[data-testid='admin-version-coherence-mismatch']")

      render_submit(view, "save", %{"app_version" => params})

      assert has_element?(view, "#flash-info", "Version saved.")

      # Still coherent after the round-trip.
      reloaded = Ash.get!(AppVersion, version.id, authorize?: false)
      assert reloaded.default_memory_mb == version.default_memory_mb
      assert reloaded.recommended_size_id == version.recommended_size_id
    end

    test "a mismatched save still fails at the action level, with its honest error", %{
      conn: conn
    } do
      version = built_version!()

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      params = app_version_params(version, %{"default_memory_mb" => "4096"})
      render_change(view, "validate", %{"app_version" => params})
      render_submit(view, "save", %{"app_version" => params})

      assert has_element?(view, "#flash-error", "Could not save the version")

      # The action's field-level error renders on the size select.
      assert has_element?(view, "p", "must match the version's allocation")

      # The row did not move.
      assert Ash.get!(AppVersion, version.id, authorize?: false).default_memory_mb == 256
    end
  end

  describe "re-pointing (the sanctioned first half of a size move)" do
    test "the consequence copy rides the change, and a matching save re-points", %{conn: conn} do
      version = built_version!()

      other =
        PricingFixtures.size!(%{
          slug: "repoint-#{@n}",
          cpu_cores: Decimal.new("2"),
          memory_mb: 4096,
          storage_gb: 50
        })

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      # Defaults matching the OTHER size: coherent, but the version
      # moves. Both callouts state what that means.
      params =
        app_version_params(version, %{
          "recommended_size_id" => other.id,
          "default_cpu_cores" => "2",
          "default_memory_mb" => "4096",
          "default_storage_gb" => "50"
        })

      render_change(view, "validate", %{"app_version" => params})

      assert has_element?(
               view,
               "[data-testid='admin-version-repoint']",
               "This version will point at #{other.slug}"
             )

      assert has_element?(
               view,
               "[data-testid='admin-version-repoint']",
               "Future deploys provision and bill"
             )

      refute has_element?(view, "[data-testid='admin-version-coherence-mismatch']")

      render_submit(view, "save", %{"app_version" => params})

      assert has_element?(view, "#flash-info", "Version saved.")
      assert Ash.get!(AppVersion, version.id, authorize?: false).recommended_size_id == other.id
    end

    test "a re-point that drifts the defaults fails at the action level", %{conn: conn} do
      version = built_version!()

      other =
        PricingFixtures.size!(%{
          slug: "repoint-bad-#{@n}",
          cpu_cores: Decimal.new("2"),
          memory_mb: 4096,
          storage_gb: 50
        })

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      # The version moves, the defaults stay: the definition of a fork.
      params = app_version_params(version, %{"recommended_size_id" => other.id})

      render_change(view, "validate", %{"app_version" => params})

      assert has_element?(view, "[data-testid='admin-version-coherence-mismatch']")
      assert has_element?(view, "[data-testid='admin-version-repoint']")

      render_submit(view, "save", %{"app_version" => params})

      assert has_element?(view, "#flash-error", "Could not save the version")

      assert Ash.get!(AppVersion, version.id, authorize?: false).recommended_size_id ==
               version.recommended_size_id
    end
  end

  describe "the first-run contract" do
    test "adding a contract saves it parsed", %{conn: conn} do
      version = built_version!()

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      params =
        app_version_params(version, %{
          "first_run_pattern" => "first_registered_user_admin",
          "first_run_env" => "ADMIN_USER=admin\nPLAIN_KEY\nSETUP_TOKEN=one=two",
          "first_run_forbidden" => "registration_enabled\nsetup_locked",
          "first_run_guidance" => "First registration owns the admin seat."
        })

      render_change(view, "validate", params)
      render_submit(view, "save", params)

      assert has_element?(view, "#flash-info", "Version saved.")

      contract = Ash.get!(AppVersion, version.id, authorize?: false).first_run
      assert contract.pattern == :first_registered_user_admin

      # A key-only line reads as an empty value; a value keeps its "=".
      assert contract.env == %{
               "ADMIN_USER" => "admin",
               "PLAIN_KEY" => "",
               "SETUP_TOKEN" => "one=two"
             }

      assert contract.forbidden_env == ["registration_enabled", "setup_locked"]
      assert contract.guidance == "First registration owns the admin seat."
    end

    test "a contract key overlapping an existing env var fails loudly, in the form", %{
      conn: conn
    } do
      # The overlap is case-insensitive (the validator's rule): the
      # contract key ADMIN_USER vs the shipped default admin_user.
      version = built_version!(%{default_env_vars: %{"admin_user" => "nope"}})

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      params =
        app_version_params(version, %{
          "first_run_pattern" => "first_registered_user_admin",
          "first_run_env" => "ADMIN_USER=admin",
          "first_run_guidance" => "First registration owns the admin seat."
        })

      # Surfaced on the change, before any submit.
      render_change(view, "validate", params)

      assert has_element?(
               view,
               "[data-testid='admin-version-firstrun-errors']",
               "the contract is the sole owner of its keys"
             )

      render_submit(view, "save", params)

      assert has_element?(view, "#flash-error", "Could not save the version")
      assert is_nil(Ash.get!(AppVersion, version.id, authorize?: false).first_run)
    end

    test "removing a contract takes the No contract path", %{conn: conn} do
      {:ok, contracted} =
        AppVersion.update(
          InstanceFixtures.app_version!(),
          %{
            first_run: %{
              pattern: "first_open_sets_password",
              env: %{"POSTGRES_PASSWORD" => "secret"},
              forbidden_env: ["registration_enabled"],
              guidance: "Set the password on first open."
            }
          },
          authorize?: false
        )

      version = Ash.load!(contracted, [:app, :recommended_size])

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      # The select shows the contract's own pattern, not No contract.
      assert has_element?(
               view,
               "[data-testid='admin-version-firstrun-pattern'] option[value='first_open_sets_password'][selected]"
             )

      params =
        app_version_params(version, %{
          "first_run_pattern" => "",
          "first_run_env" => "POSTGRES_PASSWORD=secret",
          "first_run_forbidden" => "registration_enabled",
          "first_run_guidance" => "Set the password on first open."
        })

      render_change(view, "validate", params)
      render_submit(view, "save", params)

      assert has_element?(view, "#flash-info", "Version saved.")
      assert is_nil(Ash.get!(AppVersion, version.id, authorize?: false).first_run)
    end

    test "guidance is required while a pattern is set (the honest failure)", %{conn: conn} do
      version = built_version!()

      {:ok, view, _html} = live(conn, "/admin/catalog/versions/#{version.id}")

      params =
        app_version_params(version, %{
          "first_run_pattern" => "first_open_sets_password",
          "first_run_guidance" => ""
        })

      render_change(view, "validate", params)

      assert has_element?(view, "[data-testid='admin-version-firstrun-errors']", "guidance")
    end
  end

  # The enforcement half of the pin: a crafted direct write — the same
  # update action, the platform-admin actor, authorize?: true — still
  # fails on a defaults drift, and a non-admin actor is Forbidden
  # outright (the policies decide, never the UI).
  test "the match rule still enforces at the action level", %{admin: admin} do
    version = built_version!()

    assert {:error, %Ash.Error.Invalid{errors: [error | _errors]}} =
             AppVersion.update(version, %{default_memory_mb: 4096},
               actor: admin,
               authorize?: true
             )

    assert error.field == :recommended_size_id
    assert error.message == "must match the version's allocation"

    assert Ash.get!(AppVersion, version.id, authorize?: false).default_memory_mb == 256
  end

  test "a non-admin actor is Forbidden on the write" do
    user = SessionHelpers.user!()
    version = built_version!()

    assert {:error, %Ash.Error.Forbidden{}} =
             AppVersion.update(version, %{release_notes: "crafted"},
               actor: user,
               authorize?: true
             )

    assert Ash.get!(AppVersion, version.id, authorize?: false).release_notes == nil
  end

  # The precondition chain: category, app, matching size, version,
  # loaded for the page's reads.
  defp built_version!(overrides \\ %{}) do
    version = InstanceFixtures.app_version!(overrides)
    Ash.load!(version, [:app, :recommended_size])
  end

  # The form's namespace params: the version's current allocation, with
  # the overrides under test. Absent keys carry no opinion.
  defp app_version_params(version, overrides \\ %{}) do
    Map.merge(
      %{
        "recommended_size_id" => version.recommended_size_id,
        "default_cpu_cores" => Decimal.to_string(version.default_cpu_cores),
        "default_memory_mb" => Integer.to_string(version.default_memory_mb),
        "default_storage_gb" => Integer.to_string(version.default_storage_gb)
      },
      overrides
    )
  end
end

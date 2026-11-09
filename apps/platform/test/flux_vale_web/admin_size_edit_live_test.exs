defmodule FluxValeWeb.AdminSizeEditLiveTest do
  @moduledoc false

  # The size edit form (#501): prices are freely editable — on frozen
  # sizes too — with the price edit's settle reach stated honestly;
  # the compute controls lock with the count and the path named.
  # BOTH guards are pinned: surfaced pre-write through the surface AND
  # still enforced at the action level (a crafted direct write fails,
  # and a raced write through the still-open form flips the page to
  # the lock).

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-size-edit-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    InstanceFixtures.local_cluster!()

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin)}
  end

  describe "a referenced size (the freeze surfaced pre-write)" do
    test "the lock names the count and the path, with nothing to submit", %{
      conn: conn
    } do
      size = referenced_size!()

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      # The honest consequence copy: the count, then the sanctioned
      # path, naming where retirement lives today.
      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-lock']",
               "1 version points at this size"
             )

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-lock']",
               "Its compute defaults must keep matching this size"
             )

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-lock']",
               "Re-point those versions to another size, or retire them in the debug admin"
             )

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-lock']",
               "Then this compute can move."
             )

      # The locked group renders as data, not as a disabled form: a
      # Locked chip over filled read-only fields, full ink — and
      # compute only: a size carries no storage axis (#558).
      assert has_element?(view, "[data-testid='admin-size-locked-chip']", "Locked")

      assert has_element?(
               view,
               "[data-testid='admin-size-alloc-cpu']",
               Decimal.to_string(size.cpu_cores)
             )

      assert has_element?(view, "[data-testid='admin-size-alloc-memory']", "1024")
      refute has_element?(view, "[data-testid='admin-size-alloc-storage']")

      # And there is no submit at all — the action's validation, not a
      # silent server-side strip, is what would catch a bypass.
      refute has_element?(view, "#size-allocation-form")
      refute has_element?(view, "[data-testid='admin-size-alloc-save']")
    end

    test "prices stay editable on a frozen size", %{conn: conn} do
      size = referenced_size!()

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      # The prices card states what the monthly rate prices: the
      # compute class, storage aside.
      assert has_element?(
               view,
               "[data-testid='admin-size-prices']",
               "The monthly rate prices this compute class"
             )

      params = %{"size" => %{"monthly_cents" => "999"}}
      render_change(view, "validate-price", params)
      render_submit(view, "save-price", params)

      assert has_element?(view, "#flash-info", "Prices saved.")

      reloaded = Ash.get!(Size, size.id, authorize?: false)
      assert reloaded.monthly_cents == 999
      # The frozen dimensions did not move with the prices.
      assert reloaded.memory_mb == size.memory_mb
    end
  end

  describe "the price edit's reach (the settle's snapshot-then-live semantics)" do
    # The Instance read policy narrows to the actor's orgs (a filter
    # check, never a forbid), so the counted arms use instances under
    # the admin's own org; an other-org instance is invisible to the
    # count and the copy never claims it.
    test "a size with a past-grace running instance counts it", %{
      conn: conn,
      admin: admin
    } do
      size = referenced_size!()
      running_instance!(size, admin, grandfathered_until: ~U[2020-01-01T00:00:00Z])

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      assert has_element?(
               view,
               "[data-testid='admin-size-price-reach']",
               "Visible to your account: 1 running instance already settles at this rate."
             )
    end

    test "a size with an in-lock running instance counts the lock's shape", %{
      conn: conn,
      admin: admin
    } do
      size = referenced_size!()
      running_instance!(size, admin, grandfathered_until: ~U[2099-01-01T00:00:00Z])

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      assert has_element?(
               view,
               "[data-testid='admin-size-price-reach']",
               "Visible to your account: 1 more is still inside its first-year price lock"
             )
    end

    test "the reach count sees every instance — the blanket widened the read (#644)", %{
      conn: conn
    } do
      size = referenced_size!()

      other = SessionHelpers.user!()
      running_instance!(size, other, grandfathered_until: ~U[2020-01-01T00:00:00Z])

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      # ADR-0047: platform-admin reads are cross-org by construction,
      # so the reach counts another org's running instance too.
      assert has_element?(
               view,
               "[data-testid='admin-size-price-reach']",
               "already settles"
             )
    end

    test "the consequence line states the reach even with zero instances", %{
      conn: conn
    } do
      size = size!(%{slug: "quiet-price-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      assert has_element?(
               view,
               "[data-testid='admin-size-price-reach']",
               "A price edit reaches running instances on this size"
             )

      refute has_element?(
               view,
               "[data-testid='admin-size-price-reach']",
               "Visible to your account"
             )
    end
  end

  describe "a free size (the compute editable, the freeze one version away)" do
    test "the open callout explains the coming freeze and the form saves", %{
      conn: conn
    } do
      size = size!(%{slug: "free-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-open']",
               "No versions point at this size"
             )

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-open']",
               "The compute is editable now. It freezes once a version points here."
             )

      assert has_element?(view, "#size-allocation-form")

      # The form is compute only — a size carries no storage axis
      # (#558).
      refute has_element?(view, "[data-testid='admin-size-alloc-storage']")

      # cpu_cores rides the params too (the string arm of the input's
      # value read); the save keeps it equal to the record.
      params = %{
        "size" => %{
          "cpu_cores" => Decimal.to_string(size.cpu_cores),
          "memory_mb" => "2048"
        }
      }

      render_change(view, "validate-allocation", params)
      render_submit(view, "save-allocation", params)

      assert has_element?(view, "#flash-info", "Allocation saved.")

      assert Ash.get!(Size, size.id, authorize?: false).memory_mb == 2048
    end

    test "a price-only save leaves the allocation untouched, even with crafted keys", %{
      conn: conn
    } do
      size = size!(%{slug: "free-price-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      # The allocation keys ride the payload: the price panel's
      # Map.take makes them dead weight, so the two-panel split is
      # real, not presentational.
      params = %{"size" => %{"monthly_cents" => "404", "memory_mb" => "8192"}}
      render_change(view, "validate-price", params)
      render_submit(view, "save-price", params)

      assert has_element?(view, "#flash-info", "Prices saved.")

      reloaded = Ash.get!(Size, size.id, authorize?: false)
      assert reloaded.monthly_cents == 404
      assert reloaded.memory_mb == size.memory_mb
    end

    test "a negative price fails honestly and lands nowhere", %{conn: conn} do
      size = size!(%{slug: "bad-price-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      params = %{"size" => %{"monthly_cents" => "-5"}}
      render_change(view, "validate-price", params)
      render_submit(view, "save-price", params)

      assert has_element?(view, "#flash-error", "Could not save the prices")

      # The row did not move.
      assert Ash.get!(Size, size.id, authorize?: false).monthly_cents == size.monthly_cents
    end

    test "a crafted event with no size payload carries no opinion", %{conn: conn} do
      size = size!(%{slug: "empty-payload-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      render_change(view, "validate-price", %{})

      # No crash, no error, no opinion.
      assert has_element?(view, "[data-testid='admin-size-price-save']")
      assert Ash.get!(Size, size.id, authorize?: false).monthly_cents == size.monthly_cents
    end

    test "an allocation that breaks a constraint fails honestly and lands nowhere", %{
      conn: conn
    } do
      size = size!(%{slug: "bad-alloc-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      params = %{"size" => %{"memory_mb" => "0"}}
      render_change(view, "validate-allocation", params)
      render_submit(view, "save-allocation", params)

      assert has_element?(view, "#flash-error", "Could not save the allocation")

      # The row did not move.
      assert Ash.get!(Size, size.id, authorize?: false).memory_mb == size.memory_mb
    end
  end

  describe "raced writes (the page follows the server, never contradicts it)" do
    test "a raced freeze rejection re-probes and flips the page to the lock", %{conn: conn} do
      size = size!(%{slug: "raced-#{@n}"})

      # The page mounts while the size is free: the allocation form is
      # live on the page.
      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")
      assert has_element?(view, "#size-allocation-form")

      # Another admin points a version at the size while the tab is
      # open (a test precondition, the bootstrap posture).
      point_version_at!(size)

      params = %{"size" => %{"memory_mb" => "4096"}}
      render_change(view, "validate-allocation", params)
      render_submit(view, "save-allocation", params)

      # The action-level rejection lands as the card-level answer: the
      # frozen flash and the lock, not a field error on a dimension the
      # admin never touched.
      assert has_element?(
               view,
               "#flash-error",
               "The action rejected the move. This compute is frozen while versions point at it."
             )

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-lock']",
               "1 version points at this size"
             )

      refute has_element?(view, "#size-allocation-form")

      # The row did not move.
      assert Ash.get!(Size, size.id, authorize?: false).memory_mb == size.memory_mb
    end

    test "a price save follows a raced re-point into the lock", %{conn: conn} do
      size = size!(%{slug: "raced-price-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")
      refute has_element?(view, "[data-testid='admin-size-freeze-lock']")

      # The re-point lands while the tab is open...
      point_version_at!(size)

      # ...and the next price save still succeeds, then re-probes into
      # the lock.
      params = %{"size" => %{"monthly_cents" => "500"}}
      render_change(view, "validate-price", params)
      render_submit(view, "save-price", params)

      assert has_element?(view, "#flash-info", "Prices saved.")
      assert has_element?(view, "[data-testid='admin-size-freeze-lock']", "1 version")
      refute has_element?(view, "#size-allocation-form")
    end
  end

  # The enforcement half of the pin: the UI lock is explanation only.
  # A crafted direct write — the same action, the platform-admin actor,
  # authorize?: true — still fails on the frozen dimensions, and a
  # non-admin actor is Forbidden outright (the policies decide).
  test "the freeze still enforces at the action level", %{admin: admin} do
    size = referenced_size!()

    assert {:error, %Ash.Error.Invalid{errors: [error | _errors]}} =
             Size.update(size, %{memory_mb: 2048}, actor: admin, authorize?: true)

    # The validator's message is the contract; its field placement is
    # its own untouched business (this surface answers with the
    # card-level lock, not a field error).
    assert error.message =~ "compute is frozen while versions reference this size"

    # The row did not move.
    assert Ash.get!(Size, size.id, authorize?: false).memory_mb == size.memory_mb
  end

  test "a non-admin actor is Forbidden on the write" do
    user = SessionHelpers.user!()
    size = size!(%{slug: "forbidden-#{@n}"})

    assert {:error, %Ash.Error.Forbidden{}} =
             Size.update(size, %{monthly_cents: 1}, actor: user, authorize?: true)

    assert Ash.get!(Size, size.id, authorize?: false).monthly_cents == size.monthly_cents
  end

  test "an unknown size reads as not editable here", %{conn: conn} do
    missing_id = "00000000-0000-0000-0000-000000000000"

    assert {:error, {:live_redirect, %{flash: flash, to: "/admin/catalog/sizes"}}} =
             live(conn, "/admin/catalog/sizes/#{missing_id}")

    assert flash["error"] == "That size is not editable here."
  end

  # The precondition: a size one fixture version points at. The fixture
  # fabricates its own matching size, so this re-points the version
  # through the sanctioned update path first (authorize?: false — a
  # test precondition, the bootstrap posture). Coherence is compute
  # only (#558): the version's storage default rides its own axis.
  defp referenced_size! do
    size = size!(%{slug: "frozen-#{@n}"})
    point_version_at!(size)
    size
  end

  defp point_version_at!(size) do
    version = InstanceFixtures.app_version!()

    {:ok, _repointed} =
      AppVersion.update(
        version,
        %{
          default_cpu_cores: size.cpu_cores,
          default_memory_mb: size.memory_mb,
          recommended_size_id: size.id
        },
        authorize?: false
      )

    :ok
  end

  # A running instance on the size, under `owner`'s org. The status
  # walks the legal funnel; grandfathered_until pins after (the
  # system-written field, the fixtures' sanctioned path).
  defp running_instance!(size, owner, grandfathered_until: until) do
    version = InstanceFixtures.app_version!()

    {:ok, _repointed} =
      AppVersion.update(
        version,
        %{
          default_cpu_cores: size.cpu_cores,
          default_memory_mb: size.memory_mb,
          recommended_size_id: size.id
        },
        authorize?: false
      )

    instance =
      Instance.create!(
        %{
          name: "App #{System.unique_integer()}",
          app_version_id: version.id,
          env_vars: %{}
        },
        actor: owner
      )

    instance
    |> InstanceFixtures.walk_to!(:running)
    |> InstanceFixtures.pin!(
      namespace: "fluxvale-app-#{instance.id}",
      grandfathered_until: until
    )
  end

  # Local: PricingFixtures.size! still passes #558-removed keys, so the
  # edit page's preconditions go through the create action directly.
  defp size!(overrides) do
    n = System.unique_integer()

    %{
      slug: "size-#{n}",
      cpu_cores: Decimal.new("1"),
      memory_mb: 1024,
      monthly_cents: 500
    }
    |> Map.merge(Map.new(overrides))
    |> Size.create!(authorize?: false)
  end
end

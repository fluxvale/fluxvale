defmodule FluxValeWeb.AdminSizeEditLiveTest do
  @moduledoc false

  # The size edit form (#501): prices are freely editable — on frozen
  # sizes too — while the allocation controls lock with the count and
  # the path named. BOTH guards are pinned: the freeze surfaced
  # pre-write (the lock, the copy, nothing to submit) AND still
  # enforced at the action level (a crafted direct write fails).

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Identity.User
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.PricingFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-size-edit-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin)}
  end

  describe "a referenced size (the freeze surfaced pre-write)" do
    test "the lock names the count and the path, with nothing to submit", %{
      conn: conn,
      admin: admin
    } do
      size = referenced_size!(admin)

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      # The honest consequence copy: the count, then the sanctioned path.
      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-lock']",
               "1 version points at this size"
             )

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-lock']",
               "Re-point those versions to another size, or retire them"
             )

      # The allocation controls render locked (disabled inputs).
      assert has_element?(view, "#size_cpu_cores[disabled]")
      assert has_element?(view, "#size_memory_mb[disabled]")
      assert has_element?(view, "#size_storage_gb[disabled]")

      # And there is no submit at all — the action's validation, not a
      # silent server-side strip, is what would catch a bypass.
      refute has_element?(view, "#size-allocation-form")
      refute has_element?(view, "[data-testid='admin-size-alloc-save']")
    end

    test "prices stay editable on a frozen size", %{conn: conn, admin: admin} do
      size = referenced_size!(admin)

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      params = %{"size" => %{"monthly_cents" => "999", "stopped_monthly_cents" => "88"}}
      render_change(view, "validate-price", params)
      render_submit(view, "save-price", params)

      assert has_element?(view, "#flash-info", "Prices saved.")

      reloaded = Ash.get!(Size, size.id, authorize?: false)
      assert reloaded.monthly_cents == 999
      assert reloaded.stopped_monthly_cents == 88
      # The frozen dimensions did not move with the prices.
      assert reloaded.memory_mb == size.memory_mb
    end
  end

  describe "a free size (the allocation editable, the freeze one version away)" do
    test "the open callout explains the coming freeze and the form saves", %{conn: conn} do
      size = PricingFixtures.size!(%{slug: "free-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-open']",
               "No versions point at this size"
             )

      assert has_element?(
               view,
               "[data-testid='admin-size-freeze-open']",
               "It freezes once a version points here."
             )

      assert has_element?(view, "#size-allocation-form")

      # cpu_cores rides the params too (the string arm of the input's
      # value read); the save keeps it equal to the record.
      params = %{
        "size" => %{"cpu_cores" => Decimal.to_string(size.cpu_cores), "memory_mb" => "2048"}
      }

      render_change(view, "validate-allocation", params)
      render_submit(view, "save-allocation", params)

      assert has_element?(view, "#flash-info", "Allocation saved.")

      assert Ash.get!(Size, size.id, authorize?: false).memory_mb == 2048
    end

    test "a price-only save leaves the allocation untouched", %{conn: conn} do
      size = PricingFixtures.size!(%{slug: "free-price-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      params = %{"size" => %{"monthly_cents" => "404"}}
      render_change(view, "validate-price", params)
      render_submit(view, "save-price", params)

      assert has_element?(view, "#flash-info", "Prices saved.")

      reloaded = Ash.get!(Size, size.id, authorize?: false)
      assert reloaded.monthly_cents == 404
      assert reloaded.memory_mb == size.memory_mb
    end

    test "a negative price fails honestly and lands nowhere", %{conn: conn} do
      size = PricingFixtures.size!(%{slug: "bad-price-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      params = %{"size" => %{"monthly_cents" => "-5"}}
      render_change(view, "validate-price", params)
      render_submit(view, "save-price", params)

      assert has_element?(view, "#flash-error", "Could not save the prices")

      # The row did not move.
      assert Ash.get!(Size, size.id, authorize?: false).monthly_cents == size.monthly_cents
    end

    test "an allocation that breaks a constraint fails honestly and lands nowhere", %{
      conn: conn
    } do
      size = PricingFixtures.size!(%{slug: "bad-alloc-#{@n}"})

      {:ok, view, _html} = live(conn, "/admin/catalog/sizes/#{size.id}")

      params = %{"size" => %{"memory_mb" => "0"}}
      render_change(view, "validate-allocation", params)
      render_submit(view, "save-allocation", params)

      assert has_element?(view, "#flash-error", "Could not save the allocation")

      # The row did not move.
      assert Ash.get!(Size, size.id, authorize?: false).memory_mb == size.memory_mb
    end
  end

  # The enforcement half of the pin: the UI lock is explanation only.
  # A crafted direct write — the same action, the platform-admin actor,
  # authorize?: true — still fails on the frozen dimensions, and a
  # non-admin actor is Forbidden outright (the policies decide).
  test "the freeze still enforces at the action level", %{admin: admin} do
    size = referenced_size!(admin)

    assert {:error, %Ash.Error.Invalid{errors: [error | _errors]}} =
             Size.update(size, %{memory_mb: 2048}, actor: admin, authorize?: true)

    assert error.field == :cpu_cores

    assert error.message =~ "allocation is frozen while versions reference this size"

    # The row did not move.
    assert Ash.get!(Size, size.id, authorize?: false).memory_mb == size.memory_mb
  end

  test "a non-admin actor is Forbidden on the write" do
    user = SessionHelpers.user!()
    size = PricingFixtures.size!(%{slug: "forbidden-#{@n}"})

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
  # test precondition, the bootstrap posture).
  defp referenced_size!(admin) do
    size = PricingFixtures.size!(%{slug: "frozen-#{@n}"})

    version =
      Ash.load!(InstanceFixtures.app_version!(), [:recommended_size])

    {:ok, _repointed} =
      AppVersion.update(
        version,
        %{
          default_cpu_cores: size.cpu_cores,
          default_memory_mb: size.memory_mb,
          default_storage_gb: size.storage_gb,
          recommended_size_id: size.id
        },
        authorize?: false
      )

    count =
      AppVersion
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> Ash.Query.filter(recommended_size_id == ^size.id)
      |> Ash.count!(actor: admin)

    assert count == 1
    size
  end
end

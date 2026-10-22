defmodule FluxVale.Pricing.SizeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.InstanceFixtures

  defp admin do
    case User.get_by_email("admin@fluxvale.com", authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
    end
  end

  defp regular_user do
    User.create!("regular-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp size_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        slug: "size-#{System.unique_integer()}",
        cpu_cores: Decimal.new("0.5"),
        memory_mb: 512,
        storage_gb: 10,
        monthly_cents: 335,
        stopped_monthly_cents: 40
      },
      Map.new(overrides)
    )
  end

  describe "create/2" do
    test "creates with the accepted fields" do
      attrs = size_attrs()

      assert {:ok, size} = Size.create(attrs, authorize?: false)

      assert Decimal.equal?(size.cpu_cores, Decimal.new("0.5"))
      assert size.monthly_cents == 335
      assert size.stopped_monthly_cents == 40
    end

    test "rejects non-URL-shaped slugs" do
      attrs = size_attrs(%{slug: "Not A Slug"})

      assert {:error, %Ash.Error.Invalid{}} = Size.create(attrs, authorize?: false)
    end

    test "enforces unique slug — the seed's idempotency key" do
      existing = size_attrs(%{slug: "small"})
      Size.create!(existing, authorize?: false)

      attrs = size_attrs(%{slug: "small", memory_mb: 1024})

      assert {:error, %Ash.Error.Invalid{}} = Size.create(attrs, authorize?: false)
    end

    test "a size runs something: cpu_cores must be positive" do
      attrs = size_attrs(%{cpu_cores: Decimal.new("0")})

      assert {:error, %Ash.Error.Invalid{}} = Size.create(attrs, authorize?: false)
    end

    test "memory must be positive; storage may be zero (config-only apps)" do
      no_memory = size_attrs(%{memory_mb: 0})
      config_only = size_attrs(%{storage_gb: 0})

      assert {:error, %Ash.Error.Invalid{}} = Size.create(no_memory, authorize?: false)

      assert {:ok, _size} = Size.create(config_only, authorize?: false)
    end

    test "prices are non-negative integer cents" do
      negative_running = size_attrs(%{monthly_cents: -1})
      negative_stopped = size_attrs(%{stopped_monthly_cents: -1})

      assert {:error, %Ash.Error.Invalid{}} = Size.create(negative_running, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = Size.create(negative_stopped, authorize?: false)
    end
  end

  describe "get_by_slug/1" do
    test "fetches by slug or errors" do
      attrs = size_attrs(%{slug: "small"})
      created = Size.create!(attrs, authorize?: false)

      assert {:ok, fetched} = Size.get_by_slug("small", authorize?: false)
      assert fetched.id == created.id

      assert {:error, _not_found} = Size.get_by_slug("nope", authorize?: false)
    end
  end

  describe "update/2" do
    test "reprices but keeps the slug — the seed's lookup key" do
      attrs = size_attrs(%{slug: "small"})
      size = Size.create!(attrs, authorize?: false)

      assert {:ok, updated} = Size.update(size, %{monthly_cents: 299}, authorize?: false)
      assert updated.monthly_cents == 299

      assert {:error, %Ash.Error.Invalid{}} =
               Size.update(size, %{slug: "renamed"}, authorize?: false)
    end
  end

  describe "policy (ADR-0027: mutations ride ActorIsPlatformAdmin)" do
    setup do
      %{admin: admin(), regular: regular_user()}
    end

    test "public read — anonymous browse included (#164); mutations stay admin-gated", %{
      regular: regular
    } do
      Size.create!(size_attrs(), authorize?: false)

      assert {:ok, [_row]} = Ash.read(Size, actor: regular, authorize?: true)

      assert {:ok, [_row]} = Ash.read(Size, authorize?: true)

      blocked = size_attrs(%{slug: "blocked"})

      assert {:error, %Ash.Error.Forbidden{}} = Size.create(blocked, authorize?: true)
    end

    test "non-admins cannot mutate; admins create and update — the AshAdmin paths",
         %{admin: admin, regular: regular} do
      blocked = size_attrs(%{slug: "blocked"})

      assert {:error, %Ash.Error.Forbidden{}} =
               Size.create(blocked, actor: regular, authorize?: true)

      size = Size.create!(size_attrs(), authorize?: false)

      assert {:ok, updated} =
               Ash.update(size, %{monthly_cents: 299}, actor: admin, authorize?: true)

      assert updated.monthly_cents == 299

      assert :ok = Ash.destroy(updated, actor: admin, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(size, %{monthly_cents: 1}, actor: regular, authorize?: true)
    end
  end

  describe "allocation freeze (#125)" do
    test "repricing a referenced size is free — the admin path this resource exists for" do
      version = InstanceFixtures.app_version!()
      size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

      assert {:ok, repriced} = Size.update(size, %{monthly_cents: 299}, authorize?: false)
      assert repriced.monthly_cents == 299
    end

    test "reallocating a referenced size is rejected — re-point versions first" do
      version = InstanceFixtures.app_version!()
      size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

      for allocation <- [%{memory_mb: 1024}, %{cpu_cores: Decimal.new("1")}, %{storage_gb: 50}] do
        assert {:error, error} = Size.update(size, allocation, authorize?: false)
        assert Exception.message(error) =~ "allocation is frozen"
      end
    end

    test "reallocating an unreferenced size is fine" do
      size = Size.create!(size_attrs(), authorize?: false)

      assert {:ok, moved} =
               Size.update(size, %{memory_mb: 1024, storage_gb: 20}, authorize?: false)

      assert moved.memory_mb == 1024
    end

    test "destroy fails on the FK — versions reference sizes, no cascade" do
      version = InstanceFixtures.app_version!()
      size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

      # Raw Ecto constraint (Size declares no has_many for ash_postgres to
      # map it through) — the class is plumbing, the block is the point.
      assert {:error, _blocked} = Ash.destroy(size, authorize?: false)

      assert {:ok, [_still_there]} = Ash.read(Size, authorize?: false)
    end
  end

  describe "format_usd/1" do
    test "integer cents render as a dollar string" do
      assert Pricing.format_usd(0) == "$0.00"
      assert Pricing.format_usd(5) == "$0.05"
      assert Pricing.format_usd(20) == "$0.20"
      # micro and pro at B′ (#206) — values a reader can triangulate
      # against the live table.
      assert Pricing.format_usd(283) == "$2.83"
      assert Pricing.format_usd(1606) == "$16.06"
      assert Pricing.format_usd(160_600) == "$1606.00"
    end
  end
end

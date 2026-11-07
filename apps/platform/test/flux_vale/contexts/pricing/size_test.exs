defmodule FluxVale.Pricing.SizeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.PricingFixtures

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
        monthly_cents: 295
      },
      Map.new(overrides)
    )
  end

  describe "create/2" do
    test "creates with the accepted fields — compute only (#558)" do
      attrs = size_attrs()

      assert {:ok, size} = Size.create(attrs, authorize?: false)

      assert Decimal.equal?(size.cpu_cores, Decimal.new("0.5"))
      assert size.memory_mb == 512
      assert size.monthly_cents == 295

      # The row carries no storage axis: a compute class prices CPU +
      # memory, and the stopped fee (storage alone) can't ride it.
      refute Map.has_key?(size, :storage_gb)
      refute Map.has_key?(size, :stopped_monthly_cents)
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

    test "memory must be positive" do
      no_memory = size_attrs(%{memory_mb: 0})

      assert {:error, %Ash.Error.Invalid{}} = Size.create(no_memory, authorize?: false)
    end

    test "prices are non-negative integer cents" do
      negative_running = size_attrs(%{monthly_cents: -1})

      assert {:error, %Ash.Error.Invalid{}} = Size.create(negative_running, authorize?: false)
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

  describe "compute freeze (#125, #558)" do
    test "repricing a referenced size is free — the admin path this resource exists for" do
      version = InstanceFixtures.app_version!()
      size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

      assert {:ok, repriced} = Size.update(size, %{monthly_cents: 299}, authorize?: false)
      assert repriced.monthly_cents == 299
    end

    test "re-computing a referenced size is rejected — re-point versions first" do
      version = InstanceFixtures.app_version!()
      size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

      for compute <- [%{memory_mb: 1024}, %{cpu_cores: Decimal.new("1")}] do
        assert {:error, error} = Size.update(size, compute, authorize?: false)
        assert Exception.message(error) =~ "compute is frozen"
      end
    end

    test "re-computing an unreferenced size is fine" do
      size = Size.create!(size_attrs(), authorize?: false)

      assert {:ok, moved} = Size.update(size, %{memory_mb: 1024}, authorize?: false)

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
      # micro's compute rate at B′ (#206, #558) and a round figure a
      # reader can triangulate.
      assert Pricing.format_usd(259) == "$2.59"
      assert Pricing.format_usd(1606) == "$16.06"
      assert Pricing.format_usd(160_600) == "$1606.00"
    end
  end

  # #398: the catalog cards' from-price — computed over the public read
  # on every call (never a literal), so admin reprices move every card.
  describe "from_price_cents/0" do
    test "the cheapest published size's monthly rate" do
      PricingFixtures.size!(monthly_cents: 701)
      PricingFixtures.size!(monthly_cents: 233)

      assert Pricing.from_price_cents() == 233
    end

    test "nil on an unseeded table — the surfaces hide the line" do
      assert Pricing.from_price_cents() == nil
    end
  end
end

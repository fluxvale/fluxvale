defmodule FluxVale.Infrastructure.Instance.GenerateSlugTest do
  @moduledoc """
  The env-scoped slug prefix (#155). The prefix rides VM-global app env
  (`INSTANCES_SLUG_PREFIX` → runtime.exs → config), so this module is
  async: false with on_exit restore — an async test running it would
  race InstanceTest's bare-shape assertions with a prefixed slug.
  """

  use FluxVale.DataCase, async: false

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.GenerateSlug
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    on_exit(fn -> Application.delete_env(:flux_vale, :instances_slug_prefix) end)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    user = User.create!("slug-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

    %{user: user, version: version}
  end

  describe "apply_prefix/1" do
    test "nil — the prod default — mints bare labels" do
      assert GenerateSlug.apply_prefix("quiet-river-0001") == "quiet-river-0001"
    end

    test "the empty string is also bare" do
      Application.put_env(:flux_vale, :instances_slug_prefix, "")

      assert GenerateSlug.apply_prefix("quiet-river-0001") == "quiet-river-0001"
    end

    test "a set prefix namespaces the label" do
      Application.put_env(:flux_vale, :instances_slug_prefix, "stg")

      assert GenerateSlug.apply_prefix("quiet-river-0001") == "stg-quiet-river-0001"
    end
  end

  describe "validate_prefix!/1" do
    test "accepts nil, empty and DNS-label-shaped values" do
      longest_allowed = String.duplicate("a", 37)

      assert :ok = GenerateSlug.validate_prefix!(nil)
      assert :ok = GenerateSlug.validate_prefix!("")
      assert :ok = GenerateSlug.validate_prefix!("stg")
      assert :ok = GenerateSlug.validate_prefix!("stg-1")
      assert :ok = GenerateSlug.validate_prefix!(longest_allowed)
    end

    test "raises on non-DNS-label shapes" do
      for bad <- ["Stg", "-stg", "stg-", "stg_1", "stg.1"] do
        assert_raise ArgumentError, ~r/INSTANCES_SLUG_PREFIX/, fn ->
          GenerateSlug.validate_prefix!(bad)
        end
      end
    end

    # #172: the anchor is \z, not $ — `$` also matches before a trailing
    # newline, so "stg\n" would clear validation and then mint a slug
    # instance-create rejects. Both a trailing "\n" and "\r\n" must raise.
    test "raises on a trailing newline (the \\z anchor, not $)" do
      for bad <- ["stg\n", "stg\r\n"] do
        assert_raise ArgumentError, ~r/INSTANCES_SLUG_PREFIX/, fn ->
          GenerateSlug.validate_prefix!(bad)
        end
      end
    end

    test "raises past the length bound (prefix + slug ≤ 63)" do
      one_over = String.duplicate("a", 38)

      assert_raise ArgumentError, ~r/too long/, fn ->
        GenerateSlug.validate_prefix!(one_over)
      end
    end
  end

  describe "create path" do
    test "no prefix — unchanged bare shape", %{user: user, version: version} do
      assert {:ok, instance} =
               Instance.create(%{name: "Bare", app_version_id: version.id}, actor: user)

      assert Regex.match?(~r/^[a-z]+-[a-z]+-\d{4}$/, instance.slug)
    end

    test "prefix set — <prefix>-adjective-noun-####, a valid DNS label", %{
      user: user,
      version: version
    } do
      Application.put_env(:flux_vale, :instances_slug_prefix, "stg")

      assert {:ok, instance} =
               Instance.create(%{name: "Prefixed", app_version_id: version.id}, actor: user)

      assert Regex.match?(~r/^stg-[a-z]+-[a-z]+-\d{4}$/, instance.slug)
      assert Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, instance.slug)
      assert String.length(instance.slug) <= 63
    end

    test "existing slugs are untouched when a prefix arrives", %{user: user, version: version} do
      assert {:ok, existing} =
               Instance.create(%{name: "First", app_version_id: version.id}, actor: user)

      Application.put_env(:flux_vale, :instances_slug_prefix, "stg")

      assert {:ok, fresh} =
               Instance.create(%{name: "Second", app_version_id: version.id}, actor: user)

      assert String.starts_with?(fresh.slug, "stg-")
      bare = existing.slug
      assert %Instance{slug: ^bare} = Instance.get_by_id!(existing.id, authorize?: false)
    end
  end
end

defmodule FluxVale.Infrastructure.Operations.ResizePreviewTest do
  @moduledoc """
  The resize panel's price preview (#493): the SAME PricingSnapshot
  choice the `:resize` action charges through — at the recommendation
  the size row's current cents, custom the formula's, sizeless-at
  -defaults `{:ok, nil}` (the panel's no-price, no-confirm arm).
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    version = InstanceFixtures.app_version!(monthly_cents: 100, default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    {:ok, version: version, user: user()}
  end

  test "at the recommendation: the size row's compute rate plus the storage axis, both states", %{
    version: version,
    user: user
  } do
    instance = create_and_walk!(version, user)

    assert {:ok, preview} =
             Infrastructure.resize_preview(instance, %{
               cpu_cores: instance.cpu_cores,
               memory_mb: instance.memory_mb,
               storage_gb: instance.storage_gb
             })

    # The compute class (100¢) plus the 10 GB storage axis (40¢) —
    # stopped pays the axis alone (#558).
    assert preview.running_cents == 140
    assert preview.stopped_cents == 40
  end

  test "a custom allocation: the formula's cents, not the recommendation", %{
    version: version,
    user: user
  } do
    instance = create_and_walk!(version, user)

    allocation = %{
      cpu_cores: instance.cpu_cores,
      memory_mb: 512,
      storage_gb: instance.storage_gb
    }

    assert {:ok, preview} = Infrastructure.resize_preview(instance, allocation)

    rates = Pricing.price_allocation(allocation)
    assert preview.running_cents == rates.monthly_cents
    assert preview.stopped_cents == rates.stopped_monthly_cents
  end

  test "a sizeless recommendation at its defaults: {:ok, nil} — never bill a guess", %{
    user: user
  } do
    version = sizeless_version!()
    instance = create_and_walk!(version, user)

    assert {:ok, nil} =
             Infrastructure.resize_preview(instance, %{
               cpu_cores: instance.cpu_cores,
               memory_mb: instance.memory_mb,
               storage_gb: instance.storage_gb
             })
  end

  test "a pricing read that raises answers {:error, term} — the panel's :unavailable arm", %{
    version: version,
    user: user
  } do
    Mimic.copy(Pricing)
    stub(Pricing, :price_allocation, fn _allocation -> raise "pricing read failed" end)

    instance = create_and_walk!(version, user)

    # Custom candidate (memory off the defaults) — the formula arm is
    # the raiser.
    assert {:error, _raised} =
             Infrastructure.resize_preview(instance, %{
               cpu_cores: instance.cpu_cores,
               memory_mb: 512,
               storage_gb: instance.storage_gb
             })
  end

  # --- helpers --------------------------------------------------------

  defp user do
    alias FluxVale.Identity.User

    User.create!("resize-preview-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp create_and_walk!(version, user) do
    created =
      Instance.create!(%{name: "Preview me", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

    InstanceFixtures.walk_to!(created, :stopped)
  end

  # States actions can't produce: the pre-#125 shape — a version with no
  # recommended_size (the show surface's seed precedent).
  defp sizeless_version! do
    alias FluxVale.Catalog.App

    version = InstanceFixtures.app_version!()
    app = Ash.load!(version, :app, authorize?: false).app
    n = rem(System.unique_integer([:positive]), 100)

    Ash.Seed.seed!(AppVersion, %{
      version: "0.9.#{n}",
      image: "test/image:0.9",
      port: 3000,
      app_id: app.id
    })
  end
end

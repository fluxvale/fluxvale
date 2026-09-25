defmodule FluxVale.TestSupport.InstanceFixtures do
  @moduledoc """
  Preconditions for Instance tests (#73): the `local` cluster row and a
  catalog AppVersion, built through actions with `authorize?: false`
  (the repo's bootstrap posture — so the suite fails loudly when the
  create contracts change).
  """

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Infrastructure.Cluster

  @doc "Creates the single cluster row ResolveCluster pins to."
  @spec local_cluster!() :: FluxVale.Infrastructure.Cluster.t()
  def local_cluster! do
    Cluster.create!(%{name: "local-#{System.unique_integer()}"}, authorize?: false)
  end

  @doc """
  Creates a category → app → version chain. `attrs` override the
  AppVersion defaults (image, port, env maps, resource defaults).
  """
  @spec app_version!(map()) :: AppVersion.t()
  def app_version!(attrs \\ %{}) do
    n = System.unique_integer()

    category =
      Category.create!(
        %{name: "Tools #{n}", slug: "tools-#{n}", description: "test category"},
        authorize?: false
      )

    app =
      App.create!(
        %{
          name: "App #{n}",
          slug: "app-#{n}",
          tagline: "test app",
          description: "test app",
          category_id: category.id
        },
        authorize?: false
      )

    AppVersion.create!(
      %{
        version: "1.0.#{rem(n, 100)}",
        image: "registry.example.com/app:1.0",
        port: 3000,
        app_id: app.id
      }
      |> Map.merge(Map.new(attrs)),
      authorize?: false
    )
  end
end

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
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

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

  @doc """
  Pins system-written fields (namespace/deployed_at) on an
  action-created Instance via a forced `:update_status` write — the
  namespace is write-once (the deploy action owns it, and the inline
  test trigger races past `:deploying` before an assertion can observe
  it). Status itself always travels the funnel's legal chain.
  """
  @spec pin!(Instance.t(), keyword()) :: Instance.t()
  def pin!(instance, attrs) do
    base = Ash.Changeset.for_update(instance, :update_status, %{}, authorize?: false)

    changeset =
      Enum.reduce(Map.new(attrs), base, fn {key, value}, cs ->
        Ash.Changeset.force_change_attribute(cs, key, value)
      end)

    Ash.update!(changeset)
  end

  @doc """
  Advances an Instance through the funnel's legal chain to `target` —
  StatusTransition rejects shortcuts, mirroring the real triggers
  (pending→deploying→starting→running⇄stopped).
  """
  @spec walk_to!(Instance.t(), :deploying | :starting | :running | :stopped) ::
          Instance.t()
  def walk_to!(instance, target) do
    path = %{
      deploying: [:deploying],
      starting: [:deploying, :starting],
      running: [:deploying, :starting, :running],
      stopped: [:deploying, :starting, :running, :stopped]
    }

    Enum.reduce(path[target], instance, fn status, current ->
      {:ok, next} = InstanceK8s.update_status(current, status, nil)
      next
    end)
  end
end

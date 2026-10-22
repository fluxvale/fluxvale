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
  alias FluxVale.Pricing.Size

  @doc "Creates the single cluster row ResolveCluster pins to."
  @spec local_cluster!() :: FluxVale.Infrastructure.Cluster.t()
  def local_cluster! do
    Cluster.create!(%{name: "local-#{System.unique_integer()}"}, authorize?: false)
  end

  @doc """
  Creates a category → app → version chain. `attrs` override the
  AppVersion defaults (image, port, env maps, resource defaults) plus
  the fabricated size's prices (`monthly_cents`, `stopped_monthly_cents`
  — #121's settlement tests pin them) and the App's `file_access`
  (#190's snapshot tests).

  The version contract (#125) requires a `recommended_size` equal to the
  version's allocation — one is fabricated to match the effective
  defaults (resource defaults + `attrs` overrides), so callers never
  hand-sync the two.
  """
  @spec app_version!(map()) :: AppVersion.t()
  def app_version!(attrs \\ %{}) do
    n = System.unique_integer()

    {pricing, version_attrs} =
      Map.split(Map.new(attrs), [:monthly_cents, :stopped_monthly_cents, :file_access])

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
          file_access: Map.get(pricing, :file_access, false),
          category_id: category.id
        },
        authorize?: false
      )

    version_attrs =
      Map.merge(
        %{
          version: "1.0.#{rem(n, 100)}",
          image: "registry.example.com/app:1.0",
          port: 3000,
          default_cpu_cores: Decimal.new("0.5"),
          default_memory_mb: 256,
          default_storage_gb: 0,
          app_id: app.id
        },
        version_attrs
      )

    size =
      Size.create!(
        %{
          slug: "test-#{n}",
          cpu_cores: version_attrs.default_cpu_cores,
          memory_mb: version_attrs.default_memory_mb,
          storage_gb: version_attrs.default_storage_gb,
          monthly_cents: Map.get(pricing, :monthly_cents, 100),
          stopped_monthly_cents: Map.get(pricing, :stopped_monthly_cents, 10)
        },
        authorize?: false
      )

    AppVersion.create!(
      Map.put(version_attrs, :recommended_size_id, size.id),
      authorize?: false
    )
  end

  @doc """
  Creates an action-built Instance for `user` on `version` (#179's
  status-surface tests) — `pending` on creation, like the real entry.
  """
  @spec instance!(AppVersion.t(), map()) :: Instance.t()
  def instance!(version, user) do
    Instance.create!(
      %{name: "Inst #{System.unique_integer()}", app_version_id: version.id},
      actor: user
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
  (pending→deploying→starting→running⇄stopped, and #203's
  running→sleeping).
  """
  @spec walk_to!(Instance.t(), :deploying | :starting | :running | :stopped | :sleeping) ::
          Instance.t()
  def walk_to!(instance, target) do
    path = %{
      deploying: [:deploying],
      starting: [:deploying, :starting],
      running: [:deploying, :starting, :running],
      stopped: [:deploying, :starting, :running, :stopped],
      sleeping: [:deploying, :starting, :running, :sleeping]
    }

    Enum.reduce(path[target], instance, fn status, current ->
      {:ok, next} = InstanceK8s.update_status(current, status, nil)
      next
    end)
  end
end

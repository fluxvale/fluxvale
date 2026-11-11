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
  the fabricated size's `monthly_cents` (#121's settlement tests pin
  it; the stopped rate prices from the storage axis, #558), the App's
  `file_access` (#190's snapshot tests), and the App's `slug` (#232's
  wake-metric label is the catalog slug — tests pin it readable).

  The version contract (#125, #558) requires a `recommended_size`
  whose compute equals the version's cpu/memory defaults — one is
  fabricated to match, so callers never hand-sync the two. The
  version's `default_storage_gb` is the app's own storage default,
  priced per GB on its axis.
  """
  @spec app_version!(map()) :: AppVersion.t()
  def app_version!(attrs \\ %{}) do
    n = System.unique_integer()

    {pricing, version_attrs} =
      Map.split(Map.new(attrs), [
        :monthly_cents,
        :file_access,
        :app_slug,
        :icon_url
      ])

    category =
      Category.create!(
        %{name: "Tools #{n}", slug: "tools-#{n}", description: "test category"},
        authorize?: false
      )

    app =
      App.create!(
        %{
          name: "App #{n}",
          slug: Map.get(pricing, :app_slug, "app-#{n}"),
          tagline: "test app",
          description: "test app",
          file_access: Map.get(pricing, :file_access, false),
          icon_url: Map.get(pricing, :icon_url),
          category_id: category.id
        },
        authorize?: false
      )

    version_attrs =
      Map.merge(
        %{
          # #700: the version grammar (SetSortKey) rejects negative
          # patch segments — abs keeps the fixture inside it (n is
          # System.unique_integer(), which counts negative).
          version: "1.0.#{rem(abs(n), 100)}",
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
          monthly_cents: Map.get(pricing, :monthly_cents, 100)
        },
        authorize?: false
      )

    AppVersion.create!(
      Map.put(version_attrs, :recommended_size_id, size.id),
      authorize?: false
    )
  end

  # The launch registry's majors (config.exs) — the declaring tests'
  # default shape, the Docmost class.
  @backing_launch [
    %{"kind" => "postgres", "version" => "18", "url_env" => "DATABASE_URL"},
    %{"kind" => "redis", "version" => "8", "url_env" => "REDIS_URL"}
  ]

  @doc """
  Creates an AppVersion declaring bundled backing services (#612) —
  both kinds by default, overridable via `:backing_services`. Honest
  defaults (D1/D4): 1 CPU / 1024 MB / 10 GB — the defaults INCLUDE
  the service shares, so the app carve (allocation − shares) stays
  positive; callers may override like any `app_version!` attr. Each
  declared `url_env` lands in `configurable_env_vars` as the S1
  catalog contract requires (secret, optional) — and where a caller
  passes a conflicting spec for the same key, the contract's wins (a
  declaring version must validate).
  """
  @spec backing_version!(map()) :: AppVersion.t()
  def backing_version!(attrs \\ %{}) do
    attrs = Map.new(attrs)

    services = Map.get(attrs, :backing_services, @backing_launch)

    url_specs =
      Map.new(services, fn service ->
        env = service["url_env"]
        {env, %{label: env, type: :string, required: false, secret: true}}
      end)

    configurable =
      attrs
      |> Map.get(:configurable_env_vars, %{})
      |> Map.merge(url_specs)

    honest = %{
      default_cpu_cores: Decimal.new("1"),
      default_memory_mb: 1024,
      default_storage_gb: 10
    }

    base =
      honest
      |> Map.merge(Map.drop(attrs, [:backing_services, :configurable_env_vars]))
      |> Map.put(:backing_services, services)
      |> Map.put(:configurable_env_vars, configurable)

    app_version!(base)
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
  running→sleeping, #222's running→restoring).
  """
  @spec walk_to!(
          Instance.t(),
          :deploying | :starting | :running | :stopped | :sleeping | :restoring
        ) :: Instance.t()
  def walk_to!(instance, target) do
    path = %{
      deploying: [:deploying],
      starting: [:deploying, :starting],
      running: [:deploying, :starting, :running],
      stopped: [:deploying, :starting, :running, :stopped],
      sleeping: [:deploying, :starting, :running, :sleeping],
      restoring: [:deploying, :starting, :running, :restoring]
    }

    Enum.reduce(path[target], instance, fn status, current ->
      {:ok, next} = InstanceK8s.update_status(current, status, nil)
      next
    end)
  end
end

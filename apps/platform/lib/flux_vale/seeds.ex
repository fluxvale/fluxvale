defmodule FluxVale.Seeds do
  @moduledoc """
  Seed runner, callable from `priv/repo/seeds.exs` (dev, `mix setup`),
  the release's `bin/seed` (#98), and tests.

  Get-or-create rather than `Ash.Seed.seed!/2` + `upsert_identity`: Ash
  validates **all** identities before reaching the DB upsert, so the
  unique-name constraint fails even when upserting by slug. Lookup-then-
  create is the reliable idempotent shape (v1 lesson, ported) — for a
  single caller; overlapping runs race the lookup (bring-up seeds are
  operator-run, one at a time).

  Every call runs `authorize?: false` — bootstrap: there is no actor to
  authorize before seed data exists (same posture as the admin seed).
  """

  alias FluxVale.Accounts
  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Identity.User
  alias FluxVale.Identity.User.MirrorSignupEmail
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Pricing.Size
  alias FluxVale.Pricing.TaxRate
  alias FluxVale.Seeds.CatalogData
  alias FluxVale.Seeds.PricingData
  alias FluxVale.Seeds.TaxRateData

  require Ash.Query

  @admin_email "admin@fluxvale.com"

  @doc """
  The promotable bring-up seed — dev `mix setup` and the release's
  `bin/seed` run the same path: platform admin (+ its personal org) +
  prices + tax rates + catalog. Idempotent: pricing, tax rates, and the
  catalog converge, the admin get-or-creates, and the admin-org heal
  provisions at most once (see `seed_admin_org!/0`). Pricing runs before
  the catalog — versions reference a size by slug. The `local` Cluster
  row is deliberately NOT here — `seed_local_cluster!/0` stays
  dev/local-only (local_seeds.exs).
  """
  @spec seed :: :ok
  def seed do
    seed_admin!()
    seed_admin_org!()
    seed_pricing!()
    seed_tax_rates!()
    seed_catalog!()
  end

  @doc """
  Creates the bootstrap platform admin so the admin-gated surfaces
  (TestInbox #22, Ops CRUD #25/#26, AshAdmin) have a real actor. No
  AccessRule rows ship: environments gate themselves through the
  AshAdmin CRUD at bring-up (settled on #26; ADR-0023 Am. 6's
  empty-then-close). An existing non-admin occupant of the seed email
  raises — the operator resolves it; the seed neither promotes nor
  silently skips.

  Deploy-resilient (#285 review P2-2): a PENDING claim on the seed
  address is superseded atomically before the create (operator-trusted —
  the seed address is the environment's own), and a pre-T3 admin whose
  address lives only in `users.email` (no `user_emails` row) is healed
  through the collision arm instead of failing every deploy (ADR-0033's
  init container boots NotReady).

  authorize?: false — bootstrap: there is no actor to authorize before
  the first admin exists (same posture as the User#create policy
  comment).
  """
  @spec seed_admin! :: :ok
  def seed_admin! do
    case User.get_by_email(@admin_email, authorize?: false) do
      {:ok, %{platform_role: :admin}} ->
        :ok

      # Someone registered the seed email as a plain user (JIT sign-up
      # makes that possible): seeding must not silently promote or
      # silently no-op — the operator decides.
      {:ok, _squatter} ->
        raise "seed admin: #{@admin_email} exists with a non-admin role — promote or remove that user manually, then re-run"

      {:error, _not_found} ->
        # A pending claim on the seed address would collide the create
        # (unique_address) and fail every deploy — supersede it first.
        # Operator-trusted: the seed address is the environment's own.
        UserEmail.supersede_pending_claims(@admin_email)

        case create_admin() do
          {:ok, _admin} ->
            :ok

          # users.email already holds the seed address with no row the
          # table-backed identity can see (a pre-T3 pod created it).
          # Heal, then the same role gate as the verified-row arm.
          {:error, collision} ->
            heal_seed_admin!(collision)
        end
    end
  end

  defp create_admin do
    User
    |> Ash.Changeset.for_create(:create, %{email: @admin_email, platform_role: :admin})
    |> Ash.create(authorize?: false)
  end

  # The collision arm: the address belongs to a user get_by_email
  # cannot see — the old-pod shape (users.email set, no user_emails
  # row). Heal their mirror row exactly as the create path would, then
  # apply the squatter gate: an admin passes; a non-admin occupant is
  # the operator-decides raise, unchanged in spirit.
  defp heal_seed_admin!(collision) do
    case frozen_email_owner(@admin_email) do
      {:ok, %{platform_role: :admin} = admin} ->
        case MirrorSignupEmail.write_mirror_row(admin) do
          {:ok, _row} ->
            :ok

          # Race-only: the create just collided, so the address's row
          # state changed moments ago — a claim re-added mid-window, say.
          # coveralls-ignore-start - bootstrap fails loudly instead
          {:error, reason} ->
            raise "seed admin: mirror-row heal failed for #{@admin_email} — #{inspect(reason)}"
            # coveralls-ignore-stop
        end

      {:ok, %{} = _squatter} ->
        raise "seed admin: #{@admin_email} exists with a non-admin role — promote or remove that user manually, then re-run"

      # No owner at all ({:ok, nil}) or the owner read failed: the create
      # collided with a rolled-back or aborted writer, or the failure
      # was not an address collision. Bootstrap fails loudly; re-run.
      # coveralls-ignore-start - bootstrap fails loudly instead
      _owner_gone ->
        raise "seed admin: #{@admin_email} could not be created (#{Exception.message(collision)}) and no user holds it — re-run"
        # coveralls-ignore-stop
    end
  end

  defp frozen_email_owner(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(authorize?: false)
  end

  @doc """
  Ensures the bootstrap admin's personal org exists — accounts created
  before #119 never got one (provisioning rode the User create only),
  and the #122 welcome grant rides the org create, so it fires once per
  org. Delegates to `FluxVale.Accounts.provision_personal_org/1`
  (probe-first idempotent); a freshly created admin already has its org,
  so this is a no-op there.
  """
  @spec seed_admin_org! :: :ok
  def seed_admin_org! do
    admin = User.get_by_email!(@admin_email, authorize?: false)

    case Accounts.provision_personal_org(admin) do
      {:ok, _org, _created?} ->
        :ok

      # defensive: provisioning failure is a lost JIT-signup slug race or
      # a DB failure — not sequentially reachable; the seed fails loudly
      # coveralls-ignore-start
      {:error, reason} ->
        raise "seed admin org: provisioning failed — #{inspect(reason)}"

        # coveralls-ignore-stop
    end
  end

  @doc """
  Seeds catalog Categories, Apps, and AppVersions from the shipped YAML
  (`CatalogData.entries/0`). The 1-arity takes parsed entries directly —
  the test suite also drives it with fixture YAML to cover machinery
  beyond the shipped Forgejo entry (#71).

  Idempotent — records are looked up by slug (Category, App) or app_id +
  version (AppVersion); existing rows are updated to the seed attrs, so
  re-running converges the whole catalog to catalog_data.yaml. Slug and
  version are the lookup keys and immutable on update — renaming in the
  YAML orphans the old row rather than converging it.
  """
  @spec seed_catalog! :: :ok
  def seed_catalog!, do: seed_catalog!(CatalogData.entries())

  @spec seed_catalog!([map()]) :: :ok
  def seed_catalog!(entries) do
    for %{category: cat_attrs, apps: apps} <- entries do
      category = seed_category!(cat_attrs)
      seed_apps!(apps, category)
    end

    :ok
  end

  @doc """
  Seeds the priceable allocation sizes from the shipped YAML
  (`PricingData.entries/0`, #125). The 1-arity takes parsed entries
  directly — the test suite also drives it with fixture YAML.

  Idempotent — records are looked up by slug; existing rows are updated
  to the seed attrs, so re-running converges the price table to
  pricing_data.yaml. Runs before `seed_catalog!/0` (versions reference
  sizes by slug).
  """
  @spec seed_pricing! :: :ok
  def seed_pricing!, do: seed_pricing!(PricingData.entries())

  @spec seed_pricing!([map()]) :: :ok
  def seed_pricing!(entries) do
    for attrs <- entries do
      case Size.get_by_slug(attrs.slug, authorize?: false) do
        {:ok, size} ->
          # slug is the lookup key — immutable on update (see the resource).
          Size.update!(size, Map.drop(attrs, [:slug]), authorize?: false)

        {:error, _not_found} ->
          Size.create!(attrs, authorize?: false)
      end
    end

    :ok
  end

  @doc """
  Seeds the VAT rate table from the shipped YAML (`TaxRateData.entries/0`,
  #138). The 1-arity takes parsed entries directly — the test suite also
  drives it with fixture YAML.

  Idempotent — records are looked up by (country, state, effective_from);
  existing rows have their rate_bp updated to the seed attrs, so
  re-running converges the rate table to tax_rates.yaml. A new effective
  date is a new row (no `effective_to` — the next `effective_from` is
  the boundary).
  """
  @spec seed_tax_rates! :: :ok
  def seed_tax_rates!, do: seed_tax_rates!(TaxRateData.entries())

  @spec seed_tax_rates!([map()]) :: :ok
  def seed_tax_rates!(entries) do
    for attrs <- entries do
      case find_tax_rate!(attrs) do
        [rate] ->
          # (country, state, effective_from) is the lookup key —
          # immutable on update (see the resource).
          TaxRate.update!(rate, %{rate_bp: attrs.rate_bp}, authorize?: false)

        [] ->
          TaxRate.create!(attrs, authorize?: false)
      end
    end

    :ok
  end

  # nil-state (country-wide) and state rows must not collide in the
  # lookup: `state == nil` never matches in SQL, so the nil branch
  # filters is_nil explicitly.
  defp find_tax_rate!(%{country: country, state: state, effective_from: effective_from}) do
    TaxRate
    |> Ash.Query.filter(country == ^country and effective_from == ^effective_from)
    |> tax_rate_state_filter(state)
    |> Ash.read!(authorize?: false)
  end

  defp tax_rate_state_filter(query, nil), do: Ash.Query.filter(query, is_nil(state))
  defp tax_rate_state_filter(query, state), do: Ash.Query.filter(query, state == ^state)

  @doc """
  Seeds the local cluster row (#72): nil `kubeconfig_ref` is the
  in-cluster sentinel (ADR-0006 Am. 2) — the app authenticates where it
  runs, so the local row carries no credentials.

  Get-or-create only, never converges: unlike the catalog the seed has no
  content to converge — existence is the whole job, and an admin setting
  a ref on the local row is deliberate drift the seed must not revert.
  """
  @spec seed_local_cluster! :: Cluster.t()
  def seed_local_cluster! do
    case Cluster.get_by_name("local", authorize?: false) do
      {:ok, cluster} -> cluster
      {:error, _not_found} -> Cluster.create!(%{name: "local"}, authorize?: false)
    end
  end

  defp seed_apps!(apps, category) do
    for app_entry <- apps do
      {versions, app_attrs} = Map.pop!(app_entry, :versions)
      app = seed_app!(Map.put(app_attrs, :category_id, category.id))

      for version_attrs <- versions do
        seed_app_version!(Map.put(version_attrs, :app_id, app.id))
      end
    end

    :ok
  end

  defp seed_category!(attrs) do
    case Category.get_by_slug(attrs.slug, authorize?: false) do
      {:ok, category} ->
        # slug is the lookup key — immutable on update (see the resource).
        Category.update!(category, Map.drop(attrs, [:slug]), authorize?: false)

      {:error, _not_found} ->
        Category.create!(attrs, authorize?: false)
    end
  end

  defp seed_app!(attrs) do
    case App.get_by_slug(attrs.slug, authorize?: false) do
      {:ok, app} ->
        App.update!(app, Map.drop(attrs, [:slug]), authorize?: false)

      {:error, _not_found} ->
        App.create!(attrs, authorize?: false)
    end
  end

  defp seed_app_version!(attrs) do
    attrs = resolve_recommended_size!(attrs)

    # No slug to look up by — filter the read by app_id + version to detect
    # an existing row; when present, update it with the seed attrs so the
    # seed converges instead of no-op'ing on drifted data.
    existing =
      AppVersion
      |> Ash.Query.filter(app_id == ^attrs.app_id and version == ^attrs.version)
      |> Ash.read!(authorize?: false)

    case existing do
      [version] ->
        # version is the lookup key (with app_id) — immutable on update
        # (see the resource), so it's dropped from the update attrs.
        AppVersion.update!(version, Map.drop(attrs, [:app_id, :version]), authorize?: false)

      [] ->
        AppVersion.create!(attrs, authorize?: false)

      # Defensive: unique_version_per_app prevents this; only fires on data
      # drift / schema corruption.
      # coveralls-ignore-start - seed-time drift guard; forcing it needs a
      # unique-index drop, which would test the index, not the seed
      multiples ->
        raise """
        seed_app_version!/1 expected 0 or 1 existing AppVersion rows for
        app_id=#{inspect(attrs.app_id)} version=#{inspect(attrs.version)},
        got #{length(multiples)}. Possible data drift on the unique_version_per_app identity.
        """

        # coveralls-ignore-stop
    end
  end

  # The YAML names the size by slug; the row must already exist
  # (seed_pricing!/1 runs first in seed/0). A dangling reference is seed
  # data corruption — fail loudly instead of pricing a version at nil.
  defp resolve_recommended_size!(attrs) do
    {slug, attrs} = Map.pop!(attrs, :recommended_size)

    case Size.get_by_slug(slug, authorize?: false) do
      {:ok, size} ->
        Map.put(attrs, :recommended_size_id, size.id)

      {:error, _not_found} ->
        raise "catalog seed: version references unknown pricing size #{inspect(slug)} — seed_pricing!/1 must run first"
    end
  end
end

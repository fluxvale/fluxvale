# Dev-only capture seed for the resource console shots (#595): a
# handful of feature flags and access rules (slice 1's read set), plus
# slice 3's Pricing rows (a fractional-decimal size, a usec tax-rate
# stamp), so the console's index tables and forms carry real, varied
# rows. Runs through the resource actions with the seeded admin as
# actor — the same policy path the console rides. Idempotent:
# existing flags are skipped and duplicate rules, sizes, and tax rates
# are refused by their own identities, so a re-run only tops up what a
# capture deleted.
#
# AccessRule's moduledoc says rows are never seeded — that rule is
# about environment bring-up (operator-entered, #26). This is the
# dev-only capture exception: rows for screenshots on a local DB.
#
# Run from apps/platform: mix run ../e2e/fv595_seed.exs

alias FluxVale.Identity.User
alias FluxVale.Ops.AccessRule
alias FluxVale.Ops.FeatureFlag
alias FluxVale.Pricing.Size
alias FluxVale.Pricing.TaxRate

flags = [
  %{
    key: "feedback_board",
    enabled: true,
    rollout_percentage: 100,
    description: "The public feedback board, on for everyone"
  },
  %{
    key: "edge_wake_queue",
    enabled: false,
    rollout_percentage: 25,
    description: "Queue asleep-instance wakes through the edge"
  },
  %{
    key: "org_invites",
    enabled: true,
    description: "Invitation-based org growth"
  },
  # The destroy motion's sacrificial row (slice 2's GIF): the capture
  # deletes it on camera, and this seed's idempotence mints a fresh one
  # for the next run — the showcase rows above are never the casualty.
  %{
    key: "write_path_demo",
    enabled: false,
    description: "A row that exists to be deleted on camera"
  }
]

rules = [
  # :feedback, never :auth: an :auth allowlist row gates sign-in and
  # token presentation (ADR-0023), and one would strand a local admin
  # whose address is not on the list — the same lesson the tests
  # learned. These rows are capture filler for the feedback board's
  # write gate.
  %{email: "Terence@FluxVale.com", purpose: :feedback},
  %{domain: "fluxvale.com", purpose: :feedback},
  %{email: "friend@example.org", purpose: :feedback}
]

{:ok, admin} = User.get_by_email("admin@fluxvale.com", authorize?: false)

for attrs <- flags do
  case FeatureFlag.by_key(attrs.key, actor: admin) do
    {:ok, _existing} ->
      :skip

    {:error, _not_found} ->
      FeatureFlag
      |> Ash.Changeset.for_create(:create, attrs, actor: admin)
      |> Ash.create!()

      IO.puts("flag #{attrs.key} created")
  end
end

for attrs <- rules do
  result =
    AccessRule
    |> Ash.Changeset.for_create(:create, attrs, actor: admin)
    |> Ash.create()

  case result do
    {:ok, _rule} ->
      IO.puts("rule #{inspect(attrs)} created")

    # Only the per-(purpose, shape) identity refusing a re-run's
    # duplicate reads as "skipped" — anything else (a policy refusal,
    # a bad value) fails the seed loudly instead of masquerading.
    {:error, %Ash.Error.Invalid{} = error} ->
      if Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
        IO.puts("rule #{inspect(attrs)} already present, skipped")
      else
        raise error
      end

    {:error, error} ->
      raise error
  end
end

IO.puts("seed done")

# Slice 3's capture rows (Pricing): a size with a fractional cpu_cores
# so the Decimal rendering shows its raw shape, and a tax rate whose
# effective_from carries usec so the usec datetime rendering shows its
# precision. Wallets and ledger rows ride the canonical org
# provisioning — nothing to seed in Billing.
size_attrs = %{
  slug: "capture-mid",
  cpu_cores: Decimal.new("2.5"),
  memory_mb: 2048,
  monthly_cents: 1500
}

case Size |> Ash.Changeset.for_create(:create, size_attrs, actor: admin) |> Ash.create() do
  {:ok, size} ->
    IO.puts("size #{size.slug} created")

  {:error, %Ash.Error.Invalid{} = error} ->
    if Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
      IO.puts("size already present, skipped")
    else
      raise error
    end

  {:error, error} ->
    raise error
end

tax_attrs = %{country: "DE", rate_bp: 1900, effective_from: ~U[2026-01-01 00:00:00.123456Z]}

case TaxRate |> Ash.Changeset.for_create(:create, tax_attrs, actor: admin) |> Ash.create() do
  {:ok, rate} ->
    IO.puts("tax rate #{rate.country} created")

  {:error, %Ash.Error.Invalid{} = error} ->
    if Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
      IO.puts("tax rate already present, skipped")
    else
      raise error
    end

  {:error, error} ->
    raise error
end

IO.puts("pricing seed done")

# Slice 4's capture rows (Catalog): the category -> app -> version chain
# the shots browse. The version's recommended size must match its
# compute defaults (ValidateSizeMatchesAllocation) and its backing
# service's url_env must name a secret configurable env var
# (ValidateBackingServices), so the size is seeded at 1.0 / 512.
alias FluxVale.Catalog.App
alias FluxVale.Catalog.AppVersion
alias FluxVale.Catalog.Category

catalog_size =
  case Size
       |> Ash.Changeset.for_create(
         :create,
         %{
           slug: "capture-catalog",
           cpu_cores: Decimal.new("1.0"),
           memory_mb: 512,
           monthly_cents: 800
         },
         actor: admin
       )
       |> Ash.create() do
    {:ok, size} ->
      IO.puts("size #{size.slug} created")
      size

    {:error, %Ash.Error.Invalid{} = error} ->
      if Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
        Size |> Ash.Query.filter(slug: "capture-catalog") |> Ash.read_one!(actor: admin)
      else
        raise error
      end

    {:error, error} ->
      raise error
  end

catalog_category =
  case Category
       |> Ash.Changeset.for_create(
         :create,
         %{name: "Capture Tools", slug: "capture-tools"},
         actor: admin
       )
       |> Ash.create() do
    {:ok, category} ->
      IO.puts("category #{category.slug} created")
      category

    {:error, %Ash.Error.Invalid{} = error} ->
      if Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
        Category |> Ash.Query.filter(slug: "capture-tools") |> Ash.read_one!(actor: admin)
      else
        raise error
      end

    {:error, error} ->
      raise error
  end

catalog_app =
  case App
       |> Ash.Changeset.for_create(
         :create,
         %{
           name: "Capture App",
           slug: "capture-app",
           file_access: false,
           category_id: catalog_category.id
         },
         actor: admin
       )
       |> Ash.create() do
    {:ok, app} ->
      IO.puts("app #{app.slug} created")
      app

    {:error, %Ash.Error.Invalid{} = error} ->
      if Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
        App |> Ash.Query.filter(slug: "capture-app") |> Ash.read_one!(actor: admin)
      else
        raise error
      end

    {:error, error} ->
      raise error
  end

catalog_version_attrs = %{
  version: "9.9.9",
  image: "fluxvale/capture-app:9.9.9",
  port: 3000,
  healthcheck_path: "/",
  storage_mount_path: "/data",
  default_env_vars: %{"CAPTURE" => "true"},
  configurable_env_vars: %{
    "DATABASE_URL" => %{
      "label" => "Database URL",
      "type" => "string",
      "secret" => true
    },
    "SMTP_PORT" => %{
      "label" => "SMTP port",
      "description" => "The mail relay's port",
      "type" => "integer",
      "default" => 587
    }
  },
  backing_services: [
    %{"kind" => "postgres", "version" => "18", "url_env" => "DATABASE_URL"}
  ],
  default_cpu_cores: Decimal.new("1.0"),
  default_memory_mb: 512,
  default_storage_gb: 1,
  app_id: catalog_app.id,
  recommended_size_id: catalog_size.id,
  published_at: ~U[2026-11-01 00:00:00.000000Z]
}

case AppVersion
     |> Ash.Changeset.for_create(:create, catalog_version_attrs, actor: admin)
     |> Ash.create() do
  {:ok, version} ->
    IO.puts("app version #{version.version} created")

  {:error, %Ash.Error.Invalid{} = error} ->
    existing =
      AppVersion
      |> Ash.Query.filter(app_id: catalog_app.id, version: "9.9.9")
      |> Ash.read_one!(actor: admin)

    if existing && Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1)) do
      IO.puts("app version already present, skipped")
    else
      raise error
    end

  {:error, error} ->
    raise error
end

IO.puts("catalog seed done")

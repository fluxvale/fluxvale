# Dev-only staging + capture session mint for the #612 S3 wizard
# screenshots (the fv597s3_seed.exs posture): the sanctioned sign-in
# ops mint the session exactly as a real signup; the capture catalog
# rows (a DB-backed app/version no seed ships yet — S4 lands Docmost)
# ride the resource actions with `authorize?: false`, the repo's
# staging stance. Nothing secret: APP_TOKEN's captured value is a
# placeholder, and the url_env specs are inputs the wizard HIDES.
#
# Stages one app (slug docmost-shot): one version declaring
# PostgreSQL 18 + Redis 8, honest defaults 1 CPU / 1024 MB / 10 GB,
# and a configurable schema of exactly the url_env pair plus one
# visible APP_TOKEN input — so the captures show both the hidden
# inputs (step 2's note) and the floored sliders (step 3).
#
# Run from apps/platform against the dev DB:
#   mix run ../e2e/fv612s3_seed.exs
# Prints TOKEN=… APP_SLUG=docmost-shot.

require Ash.Query

# Idempotent re-runs wipe this script's prior rows first (size last —
# the version references it; the seed's own guarded-delete stance,
# done by hand here).
defmodule FluxVale.FV612S3.Wipe do
  def by_slug(resource, slug) do
    filter = Ash.Query.filter(resource, slug == ^slug)
    Ash.read!(filter, authorize?: false)
  end
end

for app <- FluxVale.FV612S3.Wipe.by_slug(FluxVale.Catalog.App, "docmost-shot") do
  versions =
    FluxVale.Catalog.AppVersion
    |> Ash.Query.filter(app_id == ^app.id)
    |> Ash.read!(authorize?: false)

  Enum.each(versions, &Ash.destroy!(&1, authorize?: false))
  Ash.destroy!(app, authorize?: false)
end

for size <- FluxVale.FV612S3.Wipe.by_slug(FluxVale.Pricing.Size, "shot-standard") do
  Ash.destroy!(size, authorize?: false)
end

for category <- FluxVale.FV612S3.Wipe.by_slug(FluxVale.Catalog.Category, "shot-databases") do
  Ash.destroy!(category, authorize?: false)
end

# The local Cluster row ResolveCluster pins to (idempotent).
FluxVale.Seeds.seed_local_cluster!()

email = "capture-fv612s3@fluxvale.com"

code_ref = :fv612s3_capture_code
:persistent_term.put(code_ref, nil)

deliver = fn _recipient, code ->
  :persistent_term.put(code_ref, code)
  {:ok, %{}}
end

{:ok, user} =
  case FluxVale.Identity.User.get_by_email(email, authorize?: false) do
    {:ok, existing} ->
      {:ok, existing}

    {:error, _not_found} ->
      FluxVale.Identity.Operations.RequestAuthCode.call(email, deliver)

      code = :persistent_term.get(code_ref, nil)

      {:ok, user, _token} = FluxVale.Identity.Operations.VerifyAuthCode.call(email, code)
      {:ok, user}
  end

{:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

category =
  FluxVale.Catalog.Category.create!(
    %{name: "Databases", slug: "shot-databases", description: "capture category"},
    authorize?: false
  )

app =
  FluxVale.Catalog.App.create!(
    %{
      name: "Docmost",
      slug: "docmost-shot",
      tagline: "Wiki and docs for your team",
      description: "capture app",
      category_id: category.id
    },
    authorize?: false
  )

size =
  FluxVale.Pricing.Size.create!(
    %{
      slug: "shot-standard",
      cpu_cores: Decimal.new("1"),
      memory_mb: 1024,
      monthly_cents: 553
    },
    authorize?: false
  )

url_spec = fn env -> %{label: env, type: :string, required: false, secret: true} end

FluxVale.Catalog.AppVersion.create!(
  %{
    version: "1.0.0",
    image: "ghcr.io/docmost/docmost:1.0",
    port: 3000,
    app_id: app.id,
    recommended_size_id: size.id,
    default_cpu_cores: Decimal.new("1"),
    default_memory_mb: 1024,
    default_storage_gb: 10,
    backing_services: [
      %{"kind" => "postgres", "version" => "18", "url_env" => "DATABASE_URL"},
      %{"kind" => "redis", "version" => "8", "url_env" => "REDIS_URL"}
    ],
    configurable_env_vars: %{
      "APP_TOKEN" => %{label: "App token", type: :string, required: false, secret: true},
      "DATABASE_URL" => url_spec.("DATABASE_URL"),
      "REDIS_URL" => url_spec.("REDIS_URL")
    },
    published_at: DateTime.utc_now()
  },
  authorize?: false
)

IO.puts("TOKEN=#{token}")
IO.puts("APP_SLUG=docmost-shot")

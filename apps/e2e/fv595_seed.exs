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

# The idempotence fallbacks below filter by their identity; without the
# require, Ash.Query.filter/2 is a runtime call to a macro and crashes.
require Ash.Query

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

# Slice 6's capture rows (Feedback): the vocabulary, a planned and
# tagged post (the show page's badge list and the set_status form), an
# open tagless post (the empty badge row and index variety), a vote and
# a comment. The post and tag actions run with the admin actor — the
# console's own path.
alias FluxVale.Feedback.Comment
alias FluxVale.Feedback.Post
alias FluxVale.Feedback.Tag
alias FluxVale.Feedback.Vote

feedback_tags =
  for {name, slug} <- [
        {"Capture Ideas", "capture-ideas"},
        {"Capture Bugs", "capture-bugs"},
        {"Capture Docs", "capture-docs"}
      ] do
    case Tag.get_by_slug(slug, actor: admin) do
      {:ok, tag} ->
        tag

      {:error, _not_found} ->
        tag = Tag.create!(%{name: name, slug: slug}, actor: admin)
        IO.puts("tag #{tag.slug} created")
        tag
    end
  end

case Post |> Ash.Query.filter(slug: "capture-post") |> Ash.read_one(actor: admin) do
  {:ok, nil} ->
    post =
      Post.create!(
        %{
          title: "Capture Post",
          description: "A capture post for the console's badge list and moderation form."
        },
        actor: admin
      )

    post = Post.set_tags!(post, %{tag_ids: Enum.map(feedback_tags, & &1.id)}, actor: admin)
    post = Post.set_status!(post, %{status: :planned}, actor: admin)
    IO.puts("post #{post.slug} created")

  {:ok, _existing} ->
    IO.puts("post capture-post already present, skipped")
end

case Post |> Ash.Query.filter(slug: "capture-draft") |> Ash.read_one(actor: admin) do
  {:ok, nil} ->
    draft =
      Post.create!(
        %{title: "Capture Draft", description: "An untagged post for the empty badge row."},
        actor: admin
      )

    IO.puts("post #{draft.slug} created")

  {:ok, _existing} ->
    IO.puts("post capture-draft already present, skipped")
end

tagged_post =
  Post |> Ash.Query.filter(slug: "capture-post") |> Ash.read_one!(actor: admin)

case Vote
     |> Ash.Query.filter(post_id == ^tagged_post.id and cast_by_user_id == ^admin.id)
     |> Ash.read_one(actor: admin) do
  {:ok, nil} ->
    vote = Vote.cast!(%{post_id: tagged_post.id}, actor: admin)
    IO.puts("vote #{vote.id} cast")

  {:ok, _existing} ->
    IO.puts("capture vote already present, skipped")
end

capture_comment = "A capture comment for the moderation view."

case Comment
     |> Ash.Query.filter(post_id == ^tagged_post.id and body == ^capture_comment)
     |> Ash.read_one(actor: admin) do
  {:ok, nil} ->
    comment = Comment.create!(%{post_id: tagged_post.id, body: capture_comment}, actor: admin)
    IO.puts("comment #{comment.id} created")

  {:ok, _existing} ->
    IO.puts("capture comment already present, skipped")
end

IO.puts("feedback seed done")

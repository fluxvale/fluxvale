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
  alias FluxVale.Accounts.Organization
  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Post.DeriveSlug
  alias FluxVale.Feedback.Tag
  alias FluxVale.Feedback.Vote
  alias FluxVale.Identity.User
  alias FluxVale.Identity.User.MirrorSignupEmail
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
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
  prices + tax rates + catalog + the feedback tag vocabulary. Idempotent:
  pricing, tax rates, the catalog, and the vocabulary converge, the
  admin get-or-creates, and the admin-org heal provisions at most once
  (see `seed_admin_org!/0`). Pricing runs before the catalog — versions
  reference a size by slug. The `local` Cluster row is deliberately NOT
  here — `seed_local_cluster!/0` stays dev/local-only (local_seeds.exs).

  Demo feedback-board content (`seed_feedback!/0`) rides on every
  runtime except production (`:seed_demo_content`): dev via config,
  staging/review/local via runtime.exs's PLATFORM_ENV rule — anything
  but "production" seeds. Prod never does — the board launches
  honestly empty (the #412 architect ruling: fabricated votes are
  invented social proof).
  """
  @spec seed :: :ok
  def seed do
    seed_admin!()
    seed_admin_org!()
    seed_pricing!()
    seed_tax_rates!()
    seed_catalog!()
    seed_tags!()
    seed_feedback_if_demo!()
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
  # row). Heal their mirror row exactly as the create path would
  # (primary only when the account has none — a promoted second address
  # stays primary; forcing it would collide the partial index and wedge
  # every deploy, review round 2 P1), then apply the squatter gate: an
  # admin passes; a non-admin occupant is the operator-decides raise,
  # unchanged in spirit.
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

      # Reachable (covered in AdminSeedTest): an admin row with a NULL
      # username AND no personal org — drifted or hand-seeded data, not
      # a deploy shape (org provisioning predates usernames and the
      # #290 backfill filled every then-existing handle; #285-window
      # old pods provisioned orgs). seed_admin!/0's heal writes the
      # mirror row and carries such a row past its gate; the org heal
      # then names the org after the handle and answers
      # {:error, :username_missing} — loudly, with the remedy in
      # docs/deployment.md's rpc block. A lost slug race or a DB
      # failure lands here too; same loud posture.
      {:error, reason} ->
        raise "seed admin org: provisioning failed — #{inspect(reason)}"
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
  pricing_data.yaml. Rows whose slug is absent from the entries are
  deleted, so the seeds carry the ladder's whole truth (#399) — the
  delete refuses loudly while instances or versions still reference a
  removed row. Runs before `seed_catalog!/0` (versions reference sizes
  by slug).
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

    delete_removed_sizes!(entries)

    :ok
  end

  # Sizes absent from the entries leave the ladder entirely (#399): the
  # YAML is the ladder's whole truth, so their rows are deleted, not
  # just skipped. The instances → pricing_sizes FK has no ON DELETE —
  # a referenced-but-deleted row is data corruption (live settlement
  # reads the row by size_id) — so the delete refuses loudly, naming
  # every blocker at once, until the references move first. Nothing is
  # destroyed when the guard fires.
  #
  # The FKs themselves are the hard backstop: with NO ACTION a destroy
  # past the guard still fails at the DB rather than corrupting. This
  # guard is the human-readable refusal that names the blockers, so the
  # operator never has to read a constraint violation. Deletes commit
  # per-row, so a mid-loop failure can leave a half-converged table —
  # deliberate for deploy-time single-process seeding: the next seed
  # run finishes the convergence, so no transaction wrap.
  defp delete_removed_sizes!(entries) do
    kept = MapSet.new(entries, & &1.slug)

    removed =
      Size
      |> Ash.Query.filter(slug not in ^MapSet.to_list(kept))
      |> Ash.read!(authorize?: false)

    blockers = Enum.flat_map(removed, &reference_blockers/1)

    case blockers do
      [] ->
        for size <- removed do
          Ash.destroy!(size, authorize?: false)
        end

      _blocked ->
        raise """
        seed pricing: sizes absent from the seed data are still referenced and cannot be deleted:
        #{Enum.map_join(blockers, "\n", &"  - #{&1}")}
        Move or remove those references first, then re-run seeds.
        """
    end
  end

  # Human-named blockers: instances carry their slug, versions carry
  # the version string plus the owning app's id.
  defp reference_blockers(size) do
    instance_blockers =
      Instance
      |> Ash.Query.filter(size_id == ^size.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&"instance #{&1.slug} (#{&1.id}) references size #{inspect(size.slug)}")

    version_blockers =
      AppVersion
      |> Ash.Query.filter(recommended_size_id == ^size.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(
        &"app version #{&1.version} (app_id #{&1.app_id}) recommends size #{inspect(size.slug)}"
      )

    instance_blockers ++ version_blockers
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

  @doc """
  Seeds the curated tag vocabulary (#412 T10): `platform` and
  `app-request`, plus one tag per catalog app slug — catalog apps are
  seeded INTO the tag list (the owner's ruling: one curated vocabulary
  subsumes the catalog-app association, so a post about Kavita carries
  the kavita tag and the /apps/:slug cross-link convention has its
  matches).

  GATE READING (deliberate, stated): these rows ride the PROMOTABLE
  seed, NOT the demo gate, unlike the board's demo posts. The demo gate
  exists for fabricated ACTIVITY — votes and posts are invented social
  proof the real data cannot back (#412 architect ruling). Vocabulary is
  not activity: a tag named kavita claims nothing happened. And the
  board renders only tags in use, so an empty vocabulary is invisible
  until real posts carry tags — prod shows nothing that its data does
  not back. The demo posts stay gated, and their tag pairings ride with
  them (inside `seed_feedback!/0`).

  Runs after `seed_catalog!/0` (the app tags enumerate the catalog's
  rows); a catalog app added later joins the vocabulary on the next
  seed run — the same convergence posture as the catalog itself.
  Idempotent — get-or-create by slug; an admin's renames are data, not
  drift. authorize?: false — bootstrap (the seed posture).
  """
  @spec seed_tags! :: :ok
  def seed_tags! do
    seed_tag!("platform", "Platform")
    seed_tag!("app-request", "App request")

    for app <- App.list!(authorize?: false) do
      seed_tag!(app.slug, app.name)
    end

    :ok
  end

  # Existence is the job (the local-Cluster posture): the seed creates
  # a missing tag and never converges an existing one — the display
  # name is admin data (curated vocabulary), not seed truth.
  defp seed_tag!(slug, name) do
    case Tag.get_by_slug(slug, authorize?: false) do
      {:ok, _tag} -> :ok
      {:error, _not_found} -> Tag.create!(%{name: name, slug: slug}, authorize?: false)
    end
  end

  # Demo board content is gated OFF everywhere and opted into per
  # runtime (the PLATFORM_ENV rule in runtime.exs): dev's config
  # sets it true so `mix setup` ships a living board, prod-mode releases
  # (staging/review/local) seed by construction whenever PLATFORM_ENV is
  # anything but "production", and prod NEVER does — runtime.exs refuses
  # the flag on a production boot, so no overlay typo alone
  # can publish fabricated votes. The architect's #412 ruling:
  # fabricated vote counts on a public indexed board are invented social
  # proof the (not-yet-existing) Vote table cannot back, and real votes
  # would compound from a fake base — prod launches honestly empty and
  # the AccessRule invite cohort fills it.
  defp seed_feedback_if_demo! do
    if Application.get_env(:flux_vale, :seed_demo_content, false) do
      seed_feedback!()
    else
      :ok
    end
  end

  # The board's starter content (#412 T4, tags T10; counters heal #471):
  # real-looking requests across the whole status workflow so the public
  # board reads as living at first bring-up. NON-PROD ONLY (see
  # seed_feedback_if_demo!/0 — the gate decides; this function itself
  # stays ungated so tests can drive it directly). Get-or-create by the
  # derived slug (lookup first — slug is derived from the title, so the
  # attrs below are authored to derive it deterministically). `votes:`
  # is how many demo orgs cast REAL votes; `comments:` bodies authored
  # by the demo commenter pool — rows through the real actions, so a
  # count never renders without content behind it (#471).
  # age_days/status_age_days backdate the display timestamps through
  # forced attribute changes: the actions stamp "now" and no action
  # accepts timestamps — the same states-actions-can't-produce posture
  # as Ash.seed!, applied so a fresh board does not render every row as
  # "just now". `tags` (optional) names vocabulary slugs the entry
  # carries — pairings ride the same demo gate as the posts.

  # Demo comment authors: stable identities so re-runs get-or-create
  # instead of piling on. Comments render the handle, and the username
  # derives from the email local part (collision-suffixed by
  # DeriveUsername, so the local part IS the handle absent a collision).
  @demo_commenters [
    "mara@fluxvale.test",
    "theo@fluxvale.test",
    "priya@fluxvale.test",
    "joss@fluxvale.test",
    "felix@fluxvale.test"
  ]

  # One vote per org per post (the DB identity), so realistic counts
  # draw from a pool of orgs. Ownerless on purpose: the public board
  # shows only the count, and owned orgs would mint signups, wallets
  # and welcome grants staging does not need. (The five commenters are
  # the documented exception: comments render a handle, so they need
  # real users, and those ride the normal JIT chain.)
  @demo_voter_pool 12

  @feedback_entries [
    %{
      slug: "terraform-provider-for-instance-management",
      title: "Terraform provider for instance management",
      description: """
      We run five instances across three apps and manage everything else with Terraform.
      A first-class provider (data sources for instances, sizes and pricing) would let us
      treat FluxVale like the rest of our stack. Even a read-only data source set would
      unblock our drift checks.
      """,
      status: :completed,
      votes: 12,
      comments: [
        "Data sources alone would unblock our drift checks. Even read-only, this is the integration we keep reaching for manually.",
        "Any timeline? We would adopt this the week it lands.",
        "Voting from us too. Five instances, three apps, one Terraform state."
      ],
      age_days: 120,
      status_age_days: 9,
      tags: ["platform"]
    },
    %{
      slug: "show-cost-estimates-in-the-deploy-wizard",
      title: "Show cost estimates in the deploy wizard",
      description: """
      The deploy stepper picks a size before it shows a price. Putting the monthly estimate
      right in the size step would save a round trip to the pricing page.
      """,
      status: :planned,
      votes: 9,
      comments: [
        "The monthly equivalent in the size step would already be a win.",
        "This bit us on our first deploy. The estimate landed after we had committed."
      ],
      age_days: 34,
      status_age_days: 12,
      tags: ["platform"]
    },
    %{
      slug: "alert-on-failing-health-checks",
      title: "Alert on failing health checks",
      description: """
      When an instance stops answering /health I want an email before my customers notice.
      A simple threshold alert (failing for N minutes) with a webhook option would cover us.
      """,
      status: :started,
      votes: 7,
      comments: [
        "A webhook option would let us page straight into on-call.",
        "Threshold plus a quiet period and this covers most of our incidents."
      ],
      age_days: 21,
      status_age_days: 3
    },
    %{
      slug: "s3-backed-offsite-backup-exports",
      title: "S3-backed offsite backup exports",
      description: """
      Restore is easy inside FluxVale, but I want a copy outside the platform for true
      disaster recovery. Point-in-time exports to my own bucket would do it.
      """,
      status: :open,
      votes: 8,
      comments: [
        "Point-in-time would be ideal, but even a weekly export puts my mind at ease.",
        "Restic compatibility would be perfect for us."
      ],
      age_days: 60,
      status_age_days: 0
    },
    %{
      slug: "cheaper-storage-for-backup-archives",
      title: "Cheaper storage for backup archives",
      description: """
      Backup archives grow forever and bill at the hot rate. A colder tier for archives
      older than 90 days would make long retention affordable.
      """,
      status: :duplicate,
      duplicate_of: "s3-backed-offsite-backup-exports",
      votes: 0,
      comments: [
        "Following the original request. A cold tier is exactly what we need."
      ],
      age_days: 15,
      status_age_days: 6
    },
    %{
      slug: "bring-back-weekly-usage-emails",
      title: "Bring back weekly usage emails",
      description: """
      The weekly digest that listed instance hours and spend stopped arriving. It was the
      one notification that kept our finance team off your support inbox.
      """,
      status: :declined,
      votes: 3,
      comments: [
        "Shame about the digest, but the API export covers us now."
      ],
      age_days: 48,
      status_age_days: 20
    },
    %{
      slug: "suspend-an-instance-from-the-cli",
      title: "Suspend an instance from the CLI",
      description: """
      The panel has the sleep button but the CLI only has destroy. A `fluxvale instance
      suspend` (and wake) would fit our deploy scripts nicely.
      """,
      status: :open,
      votes: 5,
      comments: [
        "Suspend plus wake would slot straight into our nightly scripts."
      ],
      age_days: 5,
      status_age_days: 0,
      tags: ["platform"]
    },
    %{
      slug: "kavita-continue-reading-sync-across-devices",
      title: "Kavita: continue-reading sync across devices",
      description: """
      Our household reads on a tablet and a laptop. Kavita tracks progress per device,
      so we lose our place every time we switch. Syncing the continue-reading point
      across devices would fix it.
      """,
      status: :open,
      votes: 4,
      comments: [
        "This is the single biggest quality-of-life gap for us. Two tablets and a phone in the house."
      ],
      age_days: 8,
      status_age_days: 0,
      tags: ["kavita"]
    },
    %{
      slug: "add-immich-to-the-app-catalog",
      title: "Add Immich to the app catalog",
      description: """
      Self-hosted photo backup is the biggest gap in our homelab. An Immich one-click
      deploy (with the ML job on a bigger size) would let us drop our last rented
      cloud service.
      """,
      status: :open,
      votes: 6,
      comments: [
        "Would drop our last rented cloud service the day this ships.",
        "External library support is the other half of the ask."
      ],
      age_days: 12,
      status_age_days: 0,
      tags: ["app-request"]
    }
  ]

  @doc """
  Seeds a starter set of feedback posts (fluxvale/fluxvale#412, T4) so
  non-prod boards ship with living content. Demo data, deliberately
  gated OFF for prod (fabricated activity is invented social proof) —
  `seed/0` calls it only when the runtime opted in; this function stays
  ungated for tests. Idempotent — get-or-create by the derived slug.
  A duplicate's original is listed before it in the entries, so the
  merge pointer always resolves. Entries may carry `tags` (vocabulary
  slugs — `seed_tags!/0` runs first); the pairings ride `Post.set_tags`
  under the admin actor, gated with the posts.

  Demo votes and comments are REAL rows (#471) — cast/created through
  the actions, so the counters agree with visible content by
  construction. Posts an earlier run already seeded still get activity
  minted and counters converged, which is what heals the pre-#471
  environments whose counters were stamped with no rows behind them.

  Safe under concurrent seeders (#508): every mint rides a DB identity
  (post slug, vote per org, comment per triple, commenter email, voter
  org slug), so a racing pair converges — the loser of each mint
  catches the collision and re-finds the winner's row.
  """
  @spec seed_feedback! :: :ok
  def seed_feedback!, do: seed_feedback!(@feedback_entries)

  @doc """
  Seeds a starter set of feedback posts (fluxvale/fluxvale#412, T4) so
  non-prod boards ship with living content. Demo data, deliberately
  gated OFF for prod (fabricated activity is invented social proof) —
  `seed/0` calls it only when the runtime opted in; this function stays
  ungated for tests. Idempotent — get-or-create by the derived slug.
  A duplicate's original must be listed before it in the entries, so
  the merge pointer always resolves. Entries may carry `tags`
  (vocabulary slugs — `seed_tags!/0` runs first, an unknown slug
  raises).

  The 1-arity takes entries directly — the test suite also drives it
  with fixture entries to cover the guard machinery beyond the shipped
  set (the seed_catalog!/1 shape).
  """
  @spec seed_feedback!([map()]) :: :ok
  def seed_feedback!(entries) do
    admin = User.get_by_email!(@admin_email, authorize?: false)

    entries
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} ->
      case find_feedback_post(entry.slug) do
        nil -> seed_feedback_post!(entry, admin, index)
        post -> converge_feedback_post!(entry, post, index)
      end
    end)

    :ok
  end

  defp find_feedback_post(slug) do
    Post
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!(authorize?: false)
  end

  defp seed_feedback_post!(entry, admin, index) do
    # The authored slug is forced onto the changeset (DeriveSlug skips
    # derivation when a slug is forced) so the unique_slug identity, not
    # the probe, arbitrates a seeding race (#508) — a probe-suffixed
    # loser would mint an unfindable stray post instead of converging.
    # The derivation contract still holds: a title whose derived form
    # misses the authored slug is seed-data corruption, checked before
    # the mint. The derive runs with every candidate FREE — a DB-free
    # derivation, so the answer cannot depend on racing rows — while
    # the reserved-stem rules still apply (a seeded "New!" must derive
    # "new-2", never the reserved "/feedback/new" stem).
    derived = DeriveSlug.derive_unique(entry.title, fn _candidate -> true end)

    if derived != entry.slug do
      raise "seed feedback: #{inspect(entry.title)} derives slug #{inspect(derived)}, expected #{inspect(entry.slug)} — fix the entry's title to derive it"
    end

    # The slug identity backstops the create: a seeder losing the post
    # race catches the collision and converges on the winner's row —
    # mint its activity and converge the counters, never the content
    # (the already-seeded posture, the seed_feedback!/1 find arm's
    # exact shape).
    case Post
         |> Ash.Changeset.for_create(
           :create,
           %{title: entry.title, description: String.trim(entry.description)},
           actor: admin,
           authorize?: false
         )
         |> Ash.Changeset.force_change_attribute(:slug, entry.slug)
         |> Ash.create() do
      {:ok, created} ->
        seed_feedback_post_winner!(entry, admin, created, index)

      {:error, collision} ->
        case find_feedback_post(entry.slug) do
          nil ->
            # The mint failed for a reason the slug row cannot answer
            # (a rolled-back winner, a DB failure, or a validation
            # failure a fixture entry can produce) — fail loudly naming
            # the failure (the heal_seed_admin! _owner_gone posture).
            raise "seed feedback: post #{inspect(entry.slug)} mint failed and no row holds the slug — #{Exception.message(collision)} — re-run"

          post ->
            converge_feedback_post!(entry, post, index)
        end
    end
  end

  # The winner's continuation: the slug guard, status move, tags,
  # activity, display patch, counters — unchanged.
  defp seed_feedback_post_winner!(entry, admin, created, index) do
    # The authored slug is the get-or-create key: a future entry whose
    # title no longer derives to it would mint an unfindable duplicate
    # on every re-run. Fail the seed loudly instead.
    if created.slug != entry.slug do
      raise "seed feedback: #{inspect(entry.title)} derived slug #{inspect(created.slug)}, expected #{inspect(entry.slug)} — fix the entry's title to derive it"
    end

    moved =
      if entry.status == :open do
        created
      else
        status_args = %{status: entry.status}

        status_args =
          if Map.has_key?(entry, :duplicate_of) do
            Map.put(status_args, :duplicate_of_id, duplicate_of_id!(entry))
          else
            status_args
          end

        Post.set_status!(created, status_args, actor: admin, authorize?: false)
      end

    # Tag pairings (T10) ride the real moderation action under the
    # admin actor — the same posture as the status moves. The
    # vocabulary (seed_tags!/0) runs first, so a missing tag slug is
    # seed-data corruption: fail loudly naming the slug.
    tag_ids =
      entry
      |> Map.get(:tags, [])
      |> Enum.map(&seed_tag_id!/1)

    tagged =
      case tag_ids do
        [] -> moved
        ids -> Post.set_tags!(moved, %{tag_ids: ids}, actor: admin, authorize?: false)
      end

    mint_demo_activity!(entry, tagged, index)

    # An open post never moved status — its nil status_changed_at is the
    # display signal ("Posted N ago"), so only moved rows are backdated.
    display_patch = patch_changeset(tagged, entry)
    Ash.update!(display_patch, authorize?: false)

    converge_counters!(tagged)
  end

  # An already-seeded post (an earlier run put it there): mint its demo
  # activity and converge the counters, never the content — title,
  # body, status and timestamps are admin data (the idempotency
  # posture). Convergence is what heals the pre-#471 environments
  # whose counters carried numbers with no rows behind them.
  defp converge_feedback_post!(entry, post, index) do
    mint_demo_activity!(entry, post, index)
    converge_counters!(post)
  end

  # Demo activity through the REAL actions (#471): votes cast by pool
  # orgs, comments authored by the demo pool — so the counters the
  # actions maintain always equal the visible content. Row timestamps
  # backdate the same forced-attribute way the post's do, or a fresh
  # board reads every vote and comment as "just now" under a post
  # that renders "posted 120 days ago".
  defp mint_demo_activity!(entry, post, index) do
    if entry.votes > @demo_voter_pool do
      raise "seed feedback: #{inspect(entry.slug)} names #{entry.votes} votes but the demo voter pool holds #{@demo_voter_pool} — one vote per org per post is a DB identity; grow the pool or trim the entry"
    end

    entry.votes
    |> demo_voters!(index)
    |> Enum.with_index()
    |> Enum.each(fn {org, i} -> cast_demo_vote!(post, org, entry.age_days, i) end)

    entry.comments
    |> Enum.with_index()
    |> Enum.each(fn {body, i} -> mint_demo_comment!(post, body, index, i, entry.age_days) end)
  end

  # A rotating window of the pool: neighbouring posts draw different
  # voter subsets. (An entry naming the whole pool draws the same set
  # whatever its position — the rem window covers everyone.)
  defp demo_voters!(0, _index), do: []

  defp demo_voters!(votes, index) do
    Enum.map(1..votes, fn n ->
      demo_voter_org!(rem(index + n - 1, @demo_voter_pool) + 1)
    end)
  end

  # Ownerless orgs, stable slugs: a vote is public count data, and the
  # public board renders only the count.
  defp demo_voter_org!(n) do
    slug = "demo-voters-#{String.pad_leading(Integer.to_string(n), 2, "0")}"

    case find_demo_voter_org!(slug) do
      nil ->
        # The slug identity backstops the mint (#508): a race loser
        # catches the collision and re-finds the winner's org.
        mint_or_refind!(
          fn ->
            Organization.create(%{name: "Demo voters #{n}", slug: slug}, authorize?: false)
          end,
          fn -> find_demo_voter_org!(slug) end
        )

      org ->
        org
    end
  end

  defp find_demo_voter_org!(slug) do
    Organization
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!(authorize?: false)
  end

  # A seed mint raced and lost (#508): every seed identity carries a DB
  # unique index now (the comment identity is an md5 expression index —
  # the same exact-match semantics find_comment matches with), so the
  # old find-then-create window resolves as a caught collision instead
  # of a duplicate row (or a raw crash). The re-find coming back empty
  # means the identity row cannot answer the failure — a rolled-back
  # winner, a DB failure, or a validation failure a fixture entry can
  # produce — and the seed fails loudly naming it (the heal_seed_admin!
  # _owner_gone posture).
  defp mint_or_refind!(mint, refind) do
    case mint.() do
      {:ok, row} ->
        row

      {:error, collision} ->
        case refind.() do
          nil ->
            # The mint failed for a reason the identity row cannot
            # answer (a rolled-back winner, a DB failure, or a
            # validation failure a fixture entry can produce) — fail
            # loudly naming the failure (the heal_seed_admin!
            # _owner_gone posture).
            raise "seed feedback: mint failed and no row holds the identity — #{Exception.message(collision)} — re-run"

          row ->
            row
        end
    end
  end

  defp cast_demo_vote!(post, org, age_days, i) do
    case find_vote(post.id, org.id) do
      nil ->
        # for_create opts carry the context the changes read (Ash 3.32
        # probe: run-opts on Ash.create!/cast! never reached them), and
        # the forced timestamp rides the same probe-verified shape —
        # Comment and Vote carry no update action, so backdating can
        # only happen at create. The vote identity backstops the mint
        # (#508): a race loser catches the collision and re-finds.
        mint_or_refind!(
          fn ->
            Vote
            |> Ash.Changeset.for_create(
              :cast,
              %{post_id: post.id, organization_id: org.id},
              authorize?: false
            )
            |> Ash.Changeset.force_change_attribute(:created_at, backdate(age_days, i))
            |> Ash.create()
          end,
          fn -> find_vote(post.id, org.id) end
        )

        nil

      _vote ->
        nil
    end
  end

  # Author rotation mixes the pool across posts (and within one), so
  # threads do not read like one person talking to themselves.
  defp mint_demo_comment!(post, body, entry_index, comment_index, age_days) do
    author =
      demo_commenter!(
        Enum.at(@demo_commenters, rem(entry_index + comment_index, length(@demo_commenters)))
      )

    case find_comment(post.id, author.id, body) do
      nil ->
        # The #508 identity backstops the mint: two racing seeders used
        # to both see nil here and both mint (the incident). The loser
        # catches the collision and re-finds, converging on the
        # winner's row. Backdating rides the same forced-attribute
        # shape as the vote (no update action exists).
        mint_or_refind!(
          fn ->
            Comment
            |> Ash.Changeset.for_create(
              :create,
              %{post_id: post.id, body: body},
              actor: author,
              authorize?: false
            )
            |> Ash.Changeset.force_change_attribute(
              :created_at,
              backdate(age_days, comment_index)
            )
            |> Ash.create()
          end,
          fn -> find_comment(post.id, author.id, body) end
        )

        nil

      _comment ->
        nil
    end
  end

  defp demo_commenter!(email) do
    case find_commenter!(email) do
      nil ->
        # The email identity backstops the JIT mint (#508): a race
        # loser catches the collision and re-reads the winner's user.
        mint_or_refind!(
          fn -> User.create(email, %{}, authorize?: false) end,
          fn -> find_commenter!(email) end
        )

      user ->
        user
    end
  end

  # The table-backed lookup the mint races against (nil = no verified
  # mirror row resolves the address).
  defp find_commenter!(email) do
    case User.get_by_email(email, authorize?: false) do
      {:ok, user} ->
        user

      {:error, _not_found} ->
        nil
    end
  end

  defp find_vote(post_id, org_id) do
    Vote
    |> Ash.Query.filter(post_id == ^post_id and organization_id == ^org_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp find_comment(post_id, author_id, body) do
    comments =
      Comment
      |> Ash.Query.filter(post_id == ^post_id and author_user_id == ^author_id and body == ^body)
      |> Ash.read!(authorize?: false)

    case comments do
      [] ->
        nil

      [comment] ->
        comment

      # The #508 identity makes a duplicated (post, author, body) row
      # DB-impossible; the guard stays for the corruption answer — a
      # pre-identity row or a dropped index would otherwise answer a
      # bare multi-result error on every later run — and it names the
      # dedupe instead (the seed_app_version!/1 posture). The
      # transactional DROP INDEX test drives this arm against a real
      # duplicated table.
      multiples ->
        raise "seed feedback: #{length(multiples)} comments exist for one (post, author, body) — dedupe feedback_comments, then re-run"
    end
  end

  # The truth pass (#471): counters read the ROWS, never the other way
  # around. Rows maintain the counters through their own actions; this
  # only re-derives what a drift left behind. The reload matters: the
  # caller's struct can predate this run's mint bumps, and a drifted
  # stored value that equals the row count would otherwise compare equal
  # and skip the heal.
  defp converge_counters!(post) do
    post = Ash.reload!(post, authorize?: false)
    votes = count_rows!(Vote, post.id)
    comments = count_rows!(Comment, post.id)

    if post.vote_count != votes or post.comment_count != comments do
      post
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:vote_count, votes)
      |> Ash.Changeset.force_change_attribute(:comment_count, comments)
      |> Ash.update!(authorize?: false)
    end
  end

  defp count_rows!(resource, post_id) do
    resource
    |> Ash.Query.filter(post_id == ^post_id)
    |> Ash.count!(authorize?: false)
  end

  # Vote/comment rows backdate at create (no update action exists on
  # either resource), spread day-by-day after the post itself: i = 0
  # lands a day after creation, later rows step forward to now.
  defp backdate(age_days, i), do: days_ago(max(0, age_days - i - 1))

  # A missing tag is seed-data corruption (the vocabulary seeds before
  # the demo posts) — name the operator's fix instead of a bare NotFound.
  defp seed_tag_id!(slug) do
    case Tag.get_by_slug(slug, authorize?: false) do
      {:ok, tag} ->
        tag.id

      {:error, _not_found} ->
        raise "seed feedback: entry references unknown tag #{inspect(slug)} — seed_tags!/0 must run first"
    end
  end

  # A missing original is seed-data corruption (entries are ordered, so
  # the original must already exist) — name the operator's fix instead
  # of crashing on a bare nil.
  defp duplicate_of_id!(entry) do
    case find_feedback_post(entry.duplicate_of) do
      nil ->
        raise "seed feedback: duplicate entry #{inspect(entry.slug)} references missing original #{inspect(entry.duplicate_of)} — list the original entry before the duplicate"

      original ->
        original.id
    end
  end

  # Display timestamps only: counters belong to their rows (#471) —
  # the vote/comment actions maintain them and converge_counters!
  # re-derives on drift.
  defp patch_changeset(post, entry) do
    changeset =
      post
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:created_at, days_ago(entry.age_days))

    if entry.status_age_days > 0 do
      Ash.Changeset.force_change_attribute(
        changeset,
        :status_changed_at,
        days_ago(entry.status_age_days)
      )
    else
      changeset
    end
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

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

# Dev-only capture setup for the admin feedback moderation surface
# (#501). Deterministic: every row get-or-creates by its natural key
# (post slug, tag slug, comment triple, vote per org, admin email), so
# re-runs converge to the same populated state instead of stacking
# duplicates. Brings one referenced original with its duplicate (the
# destroy-guard state), three more posts across the status vocabulary,
# tags used and unused, comments, and votes — all through the domain's
# own actions under the seeded platform admin (authorize?: false for
# preconditions, mirroring seeds).
#
# The `empty` capture phase must run BEFORE this script (a dev DB with
# no feedback posts); `full` after it.
#
# Run from apps/platform: mix run ../e2e/moderation_capture_seed.exs
# Prints FV_TOKEN for admin_moderation_screenshot.mjs.

alias FluxVale.Feedback.Comment
alias FluxVale.Feedback.Post
alias FluxVale.Feedback.Tag
alias FluxVale.Feedback.Vote
alias FluxVale.Identity.User

require Ash.Query

# The well-known dev admin (local_seeds brings it via mix setup's run
# of seeds.exs; create-on-missing keeps this script self-sufficient).
admin =
  case User.get_by_email("admin@fluxvale.com", authorize?: false) do
    {:ok, admin} ->
      admin

    {:error, _missing} ->
      User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
  end

{:ok, org} = FluxVale.Accounts.personal_org_for_user(admin.id, authorize?: false)

defmodule ModerationCaptureSeed do
  @moduledoc false
  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Tag
  alias FluxVale.Feedback.Vote

  require Ash.Query

  def post!(title, description, admin) do
    slug = slug_derive(title)

    case find_post(slug) do
      nil ->
        Post.create!(%{title: title, description: description}, actor: admin, authorize?: false)

      post ->
        post
    end
  end

  def move!(post, status, admin, opts \\ []) do
    args =
      case Keyword.fetch(opts, :duplicate_of) do
        {:ok, original} -> %{status: status, duplicate_of_id: original.id}
        :error -> %{status: status}
      end

    Post.set_status!(post, args, actor: admin)
  end

  def tag!(name, admin) do
    slug = slug_derive(name)

    case Tag.get_by_slug(slug, authorize?: false) do
      {:ok, tag} -> tag
      {:error, _missing} -> Tag.create!(%{name: name}, actor: admin, authorize?: false)
    end
  end

  def tag_post!(post, tags, admin) do
    tag_ids = Enum.map(tags, & &1.id)
    Post.set_tags!(post, %{tag_ids: tag_ids}, actor: admin)
  end

  def comment!(post, body, admin) do
    existing =
      Comment
      |> Ash.Query.filter(post_id == ^post.id and author_user_id == ^admin.id and body == ^body)
      |> Ash.read_one!(authorize?: false)

    existing || Comment.create!(%{post_id: post.id, body: body}, actor: admin)
  end

  def vote!(post, org, admin) do
    existing =
      Vote
      |> Ash.Query.filter(post_id == ^post.id and organization_id == ^org.id)
      |> Ash.read_one!(authorize?: false)

    existing || Vote.cast!(%{post_id: post.id}, actor: admin)
  end

  defp find_post(slug) do
    Post
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!(authorize?: false)
  end

  defp slug_derive(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end

export_post =
  ModerationCaptureSeed.post!(
    "Moderation capture export usage as CSV",
    """
    ## The ask

    A CSV (or JSON) export of instance usage for the billing window.

    - hours per instance
    - the rate it settled at
    - the org it belongs to

    Finance needs this monthly. The [docs](https://example.com/docs) show
    the API shape today, which is close but not close enough.
    """,
    admin
  )

charts_post =
  ModerationCaptureSeed.post!(
    "Moderation capture darker dark mode for charts",
    "The usage charts wash out in dark mode. Bring the palette down a step so the series read at night.",
    admin
  )

shortcuts_post =
  ModerationCaptureSeed.post!(
    "Moderation capture keyboard shortcuts everywhere",
    "j and k to move through lists, x to act. Every admin table deserves the same keys.",
    admin
  )

duplicate_post =
  ModerationCaptureSeed.post!(
    "Moderation capture a duplicate of the CSV export",
    "Same ask as the CSV export post, filed before we found the original.",
    admin
  )

ModerationCaptureSeed.move!(charts_post, :planned, admin)
ModerationCaptureSeed.move!(shortcuts_post, :started, admin)
ModerationCaptureSeed.move!(duplicate_post, :duplicate, admin, duplicate_of: export_post)

platform_tag = ModerationCaptureSeed.tag!("Capture platform", admin)
charts_tag = ModerationCaptureSeed.tag!("Capture charts", admin)
# The unused vocabulary entry: its delete is the one-click arm.
ModerationCaptureSeed.tag!("Capture spare tag", admin)

ModerationCaptureSeed.tag_post!(export_post, [platform_tag], admin)
ModerationCaptureSeed.tag_post!(charts_post, [charts_tag], admin)

ModerationCaptureSeed.comment!(
  export_post,
  "Finance polls this every month. A download button would end the tickets.",
  admin
)

ModerationCaptureSeed.comment!(
  charts_post,
  "Charts legible at night would genuinely change how we use the panel.",
  admin
)

ModerationCaptureSeed.vote!(export_post, org, admin)
ModerationCaptureSeed.vote!(charts_post, org, admin)
ModerationCaptureSeed.vote!(shortcuts_post, org, admin)

{:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(admin)

IO.puts("FV_TOKEN=#{token}")

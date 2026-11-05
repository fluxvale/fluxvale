# Dev-only capture setup for the feedback interactive layer (#412 T5):
# one user whose personal org is PAID (so the vote island and the
# composer render the eligible states), one post carrying a comment and
# two extra paid orgs' votes, and the session token printed for
# fv_t5_capture.mjs. A second user owns TWO orgs (paid personal, paid
# team) for the multi-org picker still. Dev screenshot data — run from
# apps/platform:
#
#   mix run ../e2e/fv_t5_seed.exs
#
# A fresh random suffix every run keeps rows collision-free in the
# long-lived dev DB (the paid_gate_seed.exs posture).

alias FluxVale.Accounts
alias FluxVale.Billing
alias FluxVale.Feedback.Comment
alias FluxVale.Feedback.Post
alias FluxVale.Feedback.Vote
alias FluxVale.Identity.User

require Ash.Query

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

# Converge: earlier runs' demo posts are removed first, so the board
# shows ONE demo row however many times this runs. The stills embed the
# board, and a stack of identical titles reads like a duplicate bug (the
# nudge even lists them all). Scoped to the seed's OWN orgs — the
# personal orgs it creates are named after the `acmelabs-` users, so a
# real user's post that happens to share the title is never touched.
# Votes and comments follow the post (FK on_delete :delete); the demo
# accounts left behind are inert.
demo_org_ids =
  FluxVale.Accounts.Organization
  |> Ash.Query.filter(slug: [ilike: "acmelabs-%"])
  |> Ash.read!(authorize?: false)
  |> Enum.map(& &1.id)

Post
|> Ash.Query.filter(title == "Add scheduled backups for instances")
|> Ash.Query.filter(organization_id in ^demo_org_ids)
|> Ash.read!(authorize?: false)
|> Enum.each(&Ash.destroy!(&1, authorize?: false))

# A friendly local part: the username (and so the org name the picker
# and the toggle render) derives from it.
user = User.create!("acmelabs-#{suffix}@fluxvale.test", %{}, authorize?: false)
{:ok, org} = Accounts.personal_org_for_user(user.id, authorize?: false)
{:ok, wallet} = Billing.ensure_wallet(org)

# One $1+ purchase — the paid-once gate's ledger shape (never welcome
# credits). The same seam BillingFixtures.mark_paid!/1 rides in tests.
{:ok, _entry} = Billing.credit_wallet(wallet, 100)

{:ok, post} =
  Post.create(
    %{
      title: "Add scheduled backups for instances",
      description: "Nightly backups with a restore button would make us actually trust deploys.",
      organization_id: org.id
    },
    actor: user
  )

{:ok, _comment} =
  Comment.create(
    %{post_id: post.id, body: "This plus a download button would be perfect."},
    actor: user
  )

# Two more paid orgs vote the post, so the still and the GIF show a
# count that actually moves.
Enum.each(1..2, fn _i ->
  voter =
    User.create!("voter-#{suffix}-#{System.unique_integer([:positive])}@fluxvale.test", %{},
      authorize?: false
    )

  {:ok, vorg} = Accounts.personal_org_for_user(voter.id, authorize?: false)
  {:ok, vwallet} = Billing.ensure_wallet(vorg)
  {:ok, _paid} = Billing.credit_wallet(vwallet, 100)

  {:ok, _vote} = Vote.cast(%{post_id: post.id, organization_id: vorg.id}, actor: voter)
end)

# The multi-org owner: paid personal org (the picker's default) plus a
# paid team org — the picker's both chips land in the allowed state.
multi = User.create!("acmelabs-multi-#{suffix}@fluxvale.test", %{}, authorize?: false)
{:ok, multi_org} = Accounts.personal_org_for_user(multi.id, authorize?: false)
{:ok, multi_wallet} = Billing.ensure_wallet(multi_org)
{:ok, _paid} = Billing.credit_wallet(multi_wallet, 100)

team =
  FluxVale.Accounts.Organization.create!(
    %{name: "Acme Labs Team #{suffix}", slug: "acme-team-#{suffix}"},
    authorize?: false
  )

{:ok, _team_wallet} = Billing.ensure_wallet(team)
{:ok, _team_paid} = Billing.credit_wallet(team, 100)

FluxVale.Accounts.Membership.create!(
  %{organization_id: team.id, user_id: multi.id, role: :owner},
  authorize?: false
)

IO.puts("FV_T5_SLUG=#{post.slug}")
IO.puts("FV_T5_TOKEN=#{elem(AshAuthentication.Jwt.token_for_user(user), 1)}")
IO.puts("FV_T5_EMAIL=#{user.email}")
IO.puts("FV_T5_MULTI_TOKEN=#{elem(AshAuthentication.Jwt.token_for_user(multi), 1)}")
IO.puts("FV_T5_MULTI_EMAIL=#{multi.email}")

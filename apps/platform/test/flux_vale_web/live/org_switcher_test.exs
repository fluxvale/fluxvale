defmodule FluxValeWeb.OrgSwitcherTest do
  @moduledoc """
  The app chrome's org switcher (#276): rendered for a signed-in actor
  beside the logo, absent from the public and anonymous chrome. Rows are
  asserted by rendered markup — one row per membership, the owned org
  labeled "Personal — username" (#285 T6), every row targeting the org's
  own home at /organizations/:slug.
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    %{user: user, conn: conn, org: AccountsFixtures.personal_org!(user)}
  end

  defp dashboard_html(conn) do
    conn
    |> get(~p"/")
    |> html_response(200)
  end

  # The panel's rows, off the whole rendered page — the selector scopes
  # to the panel div, so page links around it stay out of the count.
  defp panel_rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-testid="org-switcher-panel"] a))
    |> Enum.to_list()
  end

  defp row_text(row) do
    row
    |> LazyHTML.text()
    |> String.trim()
  end

  defp row_href(row) do
    [href] = LazyHTML.attribute(row, "href")
    href
  end

  test "single-org user: exactly one row, the personal org labeled Personal — username", %{
    conn: conn,
    user: user,
    org: org
  } do
    html = dashboard_html(conn)

    assert html =~ ~s(data-testid="org-switcher")
    assert html =~ ~s(data-testid="org-switcher-panel")
    # GitHub-style dismissal rides the shared hook on the <details>.
    assert html =~ ~s(id="org-switcher")
    assert html =~ ~s(phx-hook="DetailsDismiss")
    # The closed summary names the active context — personal by default.
    assert html =~ ~s(>Personal</span>)

    # #285 T6: no hardcoded Personal chrome row, no single-org
    # suppression — the one membership IS the personal context, labeled
    # and linked to the org's own home. One row, one destination.
    assert [row] = panel_rows(html)
    assert row_text(row) == "Personal — #{user.username}"
    assert row_href(row) == "/organizations/#{org.slug}"
  end

  test "two orgs: one row per membership, exactly one Personal-labeled", %{
    conn: conn,
    user: user,
    org: org
  } do
    team = member_org!(user)

    html = dashboard_html(conn)

    rows = panel_rows(html)
    assert length(rows) == 2

    # Personal pinned first (#276), the later org after it.
    assert row_href(hd(rows)) == "/organizations/#{org.slug}"

    personal = Enum.find(rows, &(row_text(&1) =~ "Personal"))
    assert row_text(personal) == "Personal — #{user.username}"
    assert row_href(personal) == "/organizations/#{org.slug}"

    # The other row stays name + slug — and both rows are distinct
    # destinations: no Personal row, no duplicate context.
    others = Enum.reject(rows, &(row_text(&1) =~ "Personal"))
    assert [team_row] = others
    assert row_text(team_row) =~ team.name
    assert row_text(team_row) =~ team.slug
    assert row_href(team_row) == "/organizations/#{team.slug}"
  end

  test "zero orgs (legacy shape): an empty panel, the pill claims no Personal", %{
    conn: conn,
    user: user,
    org: org
  } do
    membership = membership!(user, org)

    # System posture — the destroy policy is system-only (#119); the
    # empty shape is unreachable through actions. Honest degradation,
    # #285 T6 review: no memberships, no invented rows — and with no
    # personal org behind it, the closed pill claims nothing (the bare
    # glyph is the empty-context state).
    Ash.destroy!(membership, authorize?: false)

    html = dashboard_html(conn)

    assert html =~ ~s(data-testid="org-switcher")
    refute html =~ ~s(>Personal</span>)
    assert panel_rows(html) == []
  end

  # The member-only shape (#285 T6 review) — the same class: a user
  # whose only membership is a :member one, no personal org. No :member
  # writer ships today (#119), so the shape is system-posture-built;
  # the create action accepts :role, and dropping the personal
  # membership is the zero-org test's posture.
  test "member-only user: the team row renders, the pill claims no Personal", %{
    conn: conn
  } do
    user = SessionHelpers.user!()
    personal = AccountsFixtures.personal_org!(user)
    personal_membership = membership!(user, personal)
    Ash.destroy!(personal_membership, authorize?: false)

    team =
      Organization.create!(
        %{name: "Team Org", slug: "member-only-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    Membership.create!(
      %{organization_id: team.id, user_id: user.id, role: :member},
      authorize?: false
    )

    conn = SessionHelpers.sign_in(conn, user)
    html = dashboard_html(conn)

    assert [row] = panel_rows(html)
    assert row_text(row) =~ team.name
    assert row_text(row) =~ team.slug
    assert row_href(row) == "/organizations/#{team.slug}"
    refute html =~ ~s(>Personal</span>)
  end

  # The #285 T6 fallback: a NULL-username rollout-window row (old-pod
  # straggler — actions can't produce the state, the documented seed!
  # exception) labels its personal row from the email local part.
  test "a NULL-username row labels the personal row from the email local part", %{
    conn: conn
  } do
    int = System.unique_integer([:positive])

    straggler =
      Ash.Seed.seed!(User, %{email: "straggler-#{int}@fluxvale.test"})

    org = member_org!(straggler)
    conn = SessionHelpers.sign_in(conn, straggler)

    html = dashboard_html(conn)

    assert [row] = panel_rows(html)
    assert row_text(row) == "Personal — straggler-#{int}"
    assert row_href(row) == "/organizations/#{org.slug}"
  end

  # Layouts.public's real consumers — the #164 SEO surfaces render the
  # session-aware chrome, so a signed-in visitor proves the `apps`
  # guard, not a standalone landing template that never calls chrome.
  test "the public chrome carries no switcher, even signed in", %{conn: conn} do
    conn = get(conn, ~p"/catalog")
    html = html_response(conn, 200)

    refute html =~ ~s(data-testid="org-switcher")
    # Sanity: this really is the session-aware public chrome.
    assert html =~ ~s(data-testid="user-menu")
  end

  test "the refund policy's public chrome carries no switcher", %{conn: conn} do
    conn = get(conn, ~p"/policies/refund")
    html = html_response(conn, 200)

    refute html =~ ~s(data-testid="org-switcher")
  end

  # The live_session wiring is half of the hook's contract — every
  # assertion above rides `/`, whose view declares the pair itself.
  test "the authenticated live_session wires the hook — the switcher rides /apps", %{
    conn: conn,
    org: org
  } do
    conn = get(conn, ~p"/apps")
    html = html_response(conn, 200)

    assert html =~ ~s(data-testid="org-switcher")
    assert html =~ ~s(href="/organizations/#{org.slug}")
  end

  test "the anonymous app chrome (sign-in) carries no switcher", %{conn: conn} do
    conn = get(conn, ~p"/sign-in")
    html = html_response(conn, 200)

    refute html =~ ~s(data-testid="org-switcher")
  end

  test "current_org names the active context in the closed summary" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{name: "Acme Collective", slug: "acme"}}],
        current_org: %{name: "Acme Collective", slug: "acme"}
      )

    assert html =~ ~s(>Acme Collective</span>)

    # Below lg the label is hidden, so the active org leads the pill
    # with its initial (the user_menu glyph) while the building icon
    # demotes to lg+ — the icon alone can't say which org is active.
    # The glyph is decoration: aria-hidden keeps it out of the a11y
    # tree (the user_menu twin's pattern), pinned so a future edit
    # can't drop it silently.
    assert html =~ ~r/aria-hidden="true"[^>]*lg:hidden/
    assert html =~ ~s(lg:hidden)
    assert html =~ ~r/>\s*A\s*<\/span>/
    assert html =~ "hidden lg:block"

    personal_html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{id: "org-acme", name: "Acme Collective", slug: "acme"}}],
        personal_org_id: "org-acme"
      )

    # Personal keeps the building icon at every width — no initial —
    # and the pill reads "Personal" (a personal org exists to claim).
    refute personal_html =~ "lg:hidden"
    refute personal_html =~ "hidden lg:block"
    assert personal_html =~ ~s(>Personal</span>)

    # The empty-context shape (#285 T6 review): no org context and no
    # personal org — the pill claims nothing, the bare glyph only.
    empty_html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{name: "Acme Collective", slug: "acme"}}]
      )

    refute empty_html =~ ~s(>Personal</span>)
  end

  # The component level, off the chrome: exactly one row per membership,
  # the owned org (personal_org_id) carrying the Personal—username label.
  test "one row per membership, the owned org labeled Personal — username" do
    acme = %{organization: %{id: "org-acme", name: "Acme Collective", slug: "acme"}}
    oss = %{organization: %{id: "org-oss", name: "OSS Friends", slug: "oss-friends"}}

    single =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [acme],
        personal_org_id: "org-acme",
        username: "terence"
      )

    assert [row] = panel_rows(single)
    assert row_text(row) == "Personal — terence"
    assert row_href(row) == "/organizations/acme"

    both =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [acme, oss],
        personal_org_id: "org-acme",
        username: "terence"
      )

    rows = panel_rows(both)
    assert length(rows) == 2
    assert Enum.count(rows, &(row_text(&1) =~ "Personal")) == 1
    assert row_text(Enum.at(rows, 0)) == "Personal — terence"
    assert row_href(Enum.at(rows, 0)) == "/organizations/acme"
    assert row_text(Enum.at(rows, 1)) =~ "OSS Friends"
    assert row_text(Enum.at(rows, 1)) =~ "oss-friends"
    assert row_href(Enum.at(rows, 1)) == "/organizations/oss-friends"
  end

  # A nil handle renders the bare label, not a dangling "Personal — "
  # (#285 T6 review). Component-level only — the in-app path always
  # carries a handle (OrgNav's email fallback).
  test "a nil username renders a bare Personal label, no dangling dash" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{id: "org-acme", name: "Acme Collective", slug: "acme"}}],
        personal_org_id: "org-acme",
        username: nil
      )

    assert [row] = panel_rows(html)
    assert row_text(row) == "Personal"
    assert row_href(row) == "/organizations/acme"
  end

  # Same hazard for "": the email fallback's local_part of a degenerate
  # seed-only address ("@fluxvale.test") is "" (#308 review) — same
  # dangling-dash shape as nil, same bare-label answer.
  test "an empty-string username renders a bare Personal label, no dangling dash" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{id: "org-acme", name: "Acme Collective", slug: "acme"}}],
        personal_org_id: "org-acme",
        username: ""
      )

    assert [row] = panel_rows(html)
    assert row_text(row) == "Personal"
    assert row_href(row) == "/organizations/acme"
  end

  # The split state (#308 review): OrgNav resolves memberships and the
  # canonical personal org in two non-transactional reads — a
  # membership change straddling them can leave personal_org_id naming
  # an org the loaded rows don't carry. The pill must not claim
  # "Personal" with no Personal row behind it: it degrades to the bare
  # glyph, while the rows stay honest.
  test "split state: a personal_org_id absent from the rows degrades the pill to the glyph" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{id: "org-team", name: "Team Org", slug: "team"}}],
        personal_org_id: "org-personal",
        username: "terence"
      )

    refute html =~ ~s(>Personal</span>)
    assert [row] = panel_rows(html)
    assert row_text(row) =~ "Team Org"
    assert row_href(row) == "/organizations/team"
  end

  # The hook's unique-DOM-id contract stays caller-owned: the default
  # is "org-switcher" (the app chrome's one switcher), a caller's id
  # renders exactly once.
  test "a caller-supplied id wins over the default" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [],
        id: "my-own-switcher"
      )

    assert html =~ ~s(id="my-own-switcher")
    # data-testid="org-switcher" also contains `id="org-switcher"` as a
    # substring, so anchor on the attribute's leading space.
    refute html =~ ~s( id="org-switcher")
  end

  test "an empty org name renders the neutral glyph, not a crash" do
    html =
      render_component(&FluxValeWeb.CoreComponents.org_switcher/1,
        orgs: [%{organization: %{id: "org-empty", name: "", slug: "empty"}}],
        personal_org_id: "org-empty",
        username: "terence",
        current_org: %{name: "", slug: "empty"}
      )

    # '' names reach the DB only via raw writes/seeds (actions reject
    # them) — initial/1 is defensive shared chrome; the pill shows the
    # neutral glyph instead of raising.
    assert html =~ ~r/>\s*\?\s*<\/span>/
  end

  # The #285 T6 divergence probe, permanent: a user owning TWO orgs —
  # their signup-provisioned personal org plus an org that already
  # existed when they signed up (the reviewer's shape: the legacy org
  # row predates the user, so the canonical op's unordered pick and the
  # old min-membership-id derivation name different orgs). The
  # switcher's "Personal" label must resolve the same org the billing
  # mount (and the dashboard wallet) resolve — the canonical
  # `Accounts.personal_org_for_user/2`. Whether the canonical op's own
  # tie-break for two-owned-orgs users is the right answer is a T7
  # (identity spec) question — out of scope here; pinned is that every
  # consumer agrees on ONE answer.
  test "two-owner user: the switcher's Personal label resolves the canonical org", %{
    conn: conn
  } do
    legacy =
      Organization.create!(
        %{name: "Legacy Org", slug: "probe-legacy-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    user = SessionHelpers.user!()
    _personal = AccountsFixtures.personal_org!(user)

    # System-only create (#119) — the bootstrap posture, mirroring
    # seeds; the user now owns two orgs.
    Membership.create!(%{organization_id: legacy.id, user_id: user.id}, authorize?: false)

    {:ok, canonical} = Accounts.personal_org_for_user(user.id, actor: user)

    # The fixture stays load-bearing: the canonical pick must differ
    # from the old min-:owner-membership-id derivation this resolver
    # replaced. If the shape ever collapses (the op gains a sort
    # aligned with the old rule), the agreement assert below would
    # pass vacuously — this fails first, at fixture time.
    owners =
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(user_id == ^user.id and role == :owner)
      |> Ash.read!(authorize?: false)

    min_id_pick = Enum.min_by(owners, & &1.id)
    refute canonical.id == min_id_pick.organization_id

    conn = SessionHelpers.sign_in(conn, user)

    # The dashboard's switcher labels the canonical org "Personal" —
    # the org billing resolves; the pill and panel row name one org.
    html = dashboard_html(conn)
    rows = panel_rows(html)
    personal_rows = Enum.filter(rows, &(row_text(&1) =~ "Personal"))

    assert [personal_row] = personal_rows
    assert row_href(personal_row) == "/organizations/#{canonical.slug}"

    # The billing mount resolves the same org the switcher labels — the
    # seam this PR exists to pin, wallet-free: the canonical pick here
    # is necessarily the bare legacy org (the refute above pins it is
    # NOT the personal one, and the user owns exactly two orgs), so its
    # ledger renders the empty state; the personal org would show its
    # welcome-grant ledger-row instead (#308 round-3 review, P2).
    billing_html =
      conn
      |> get(~p"/billing")
      |> html_response(200)

    assert billing_html =~ ~s(data-testid="ledger-empty")
    refute billing_html =~ ~s(data-testid="ledger-row")
  end

  # Both creates are system-only (#119) — the bootstrap posture,
  # mirroring seeds.
  defp member_org!(user) do
    org =
      Organization.create!(
        %{name: "Team Org", slug: "team-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: user.id}, authorize?: false)

    org
  end

  defp membership!(user, org) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(user_id == ^user.id and organization_id == ^org.id)
    |> Ash.read_one!(authorize?: false)
  end
end

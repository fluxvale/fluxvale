defmodule FluxValeWeb.AdminOrgsLiveTest do
  @moduledoc false

  # The orgs surface (#501): the org table, its search, its cap, and
  # the wallet-state column. The route gates here are the shared
  # live_session's arms (the anonymous 302 and the non-admin 403,
  # pinned once per surface). The surface is read-only by design — no
  # write events exist to pin.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.AdminComponents

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-orgs-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # `{org, wallet}` with a distinct display name (the rename action is
  # owner-gated, so the precondition rides the seeds posture — these
  # tests need names to search by, not the owner's session).
  defp org_wallet!(opts \\ []) do
    {org, _owner} = BillingFixtures.grant_free_org!()

    name = Keyword.get(opts, :name, "orgs org #{@n}-#{System.unique_integer([:positive])}")
    renamed = Organization.update!(org, %{name: name}, authorize?: false)

    {:ok, wallet} = Billing.ensure_wallet(renamed)
    {renamed, wallet}
  end

  defp funded_org_wallet!(opts) do
    {org, wallet} = org_wallet!(opts)
    cents = Keyword.get(opts, :balance_cents, 10_000)

    if cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, cents, reason: :adjustment)
    end

    {org, wallet}
  end

  # A wallet below zero, anchored by the sweep's own write posture (the
  # ladder markers are states actions cannot produce — the sweep tests
  # use the same escape).
  defp negative_org_wallet!(opts) do
    {org, wallet} = funded_org_wallet!(Keyword.merge(opts, balance_cents: 500))
    {:ok, _debit} = Billing.debit_wallet(wallet, 1_000 * 10_000)

    anchored =
      wallet
      |> Ash.Changeset.for_update(
        :set_ladder_state,
        %{negative_since: DateTime.add(DateTime.utc_now(), -2, :day)},
        authorize?: false
      )
      |> Ash.update!()

    {org, anchored}
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "the org table" do
    test "lists orgs with the wallet seam's fields, the balance state, and both links", %{
      conn: conn
    } do
      {plain_org, plain} = funded_org_wallet!(name: "plain org co")
      {negative_org, negative} = negative_org_wallet!(name: "negative org co")

      {:ok, view, _html} = live(conn, "/admin/orgs")

      assert has_element?(view, "[data-testid='admin-orgs']")

      for {org, wallet} <- [{plain_org, plain}, {negative_org, negative}] do
        assert text_of(view, "[data-testid='admin-orgs-org-#{wallet.id}']") =~ org.name

        assert has_element?(
                 view,
                 "[data-testid='admin-orgs-org-link-#{wallet.id}'][href='/admin/orgs/#{org.id}']"
               )

        assert has_element?(
                 view,
                 "[data-testid='admin-orgs-open-wallet-#{wallet.id}'][href='/admin/billing/wallets/#{wallet.id}']"
               )
      end

      assert text_of(view, "[data-testid='admin-orgs-balance-#{plain.id}']") == "$100.00"

      # Positive is the resting rung: plain, no badge at all.
      assert text_of(view, "[data-testid='admin-orgs-state-#{plain.id}']") == ""

      # The wallet-since stamp is the wallet's provisioning date,
      # honestly labeled as the wallet's, not the org's.
      since = Calendar.strftime(plain.created_at, "%b %d, %Y")
      assert text_of(view, "[data-testid='admin-orgs-since-#{plain.id}']") == since
    end

    test "a negative balance reads as the countdown: tint, badge, cue, both clock dates", %{
      conn: conn
    } do
      {_negative_org, negative} = negative_org_wallet!(name: "sinking org co")
      {_plain_org, plain} = funded_org_wallet!(name: "afloat org co")

      {:ok, view, _html} = live(conn, "/admin/orgs")

      state = "[data-testid='admin-orgs-state-#{negative.id}']"
      assert has_element?(view, state, "Negative")
      assert has_element?(view, state <> " .hero-clock")

      # The whole clock object, the wallets section's grammar: the
      # anchor AND the deadline.
      anchor = Calendar.strftime(negative.negative_since, "%b %d, %Y")
      deadline = AdminComponents.destroy_deadline_text(negative.negative_since)
      state_text = text_of(view, state)
      assert state_text =~ "since #{anchor}"
      assert state_text =~ "deletes #{deadline}"

      # The tint carries the weight; the positive row carries none.
      assert render(element(view, "#wallets-#{negative.id}")) =~ "bg-danger-muted"
      refute text_of(view, "[data-testid='admin-orgs-state-#{plain.id}']") =~ "Negative"
    end

    test "a zero balance names the funded gate's block, a positive one rests unbadged", %{
      conn: conn
    } do
      {_zero_org, zero} = org_wallet!(name: "zero org co")
      {_plain_org, plain} = funded_org_wallet!(name: "funded org co")

      {:ok, view, _html} = live(conn, "/admin/orgs")

      assert text_of(view, "[data-testid='admin-orgs-state-#{zero.id}']") == "Zero"

      assert has_element?(
               view,
               "[data-testid='admin-orgs-state-#{zero.id}'] .hero-exclamation-triangle"
             )

      # The resting rung drops its badge: nothing to read on positive.
      refute has_element?(view, "[data-testid='admin-orgs-state-#{plain.id}'] .badge")
    end

    test "negative balances pin to the top, then newest provisioned first", %{conn: conn} do
      {_old_org, old} = funded_org_wallet!(name: "old org co")
      {_mid_org, mid} = funded_org_wallet!(name: "mid org co")
      {_new_org, new} = funded_org_wallet!(name: "new org co")

      {:ok, _debit} = Billing.debit_wallet(old, 5_000 * 10_000)

      old
      |> Ash.Changeset.for_update(
        :set_ladder_state,
        %{negative_since: DateTime.add(DateTime.utc_now(), -1, :day)},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/orgs")

      # The row order, read back as data: the countdown pins first, the
      # positives keep provisioning order. (The setup admin's own
      # personal-org wallet trails.)
      ids =
        view
        |> element("#admin-orgs-table")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#admin-orgs-table > div")
        |> Enum.map(fn row ->
          row
          |> LazyHTML.query("[data-testid^='admin-orgs-org-']")
          |> Enum.at(0)
          |> LazyHTML.attribute("data-testid")
          |> Enum.join("")
          |> String.replace_prefix("admin-orgs-org-", "")
        end)

      assert Enum.take(ids, 3) == [old.id, new.id, mid.id]
    end

    test "search narrows the list by org name or slug and never reaches past it", %{
      conn: conn
    } do
      {_alpha_org, alpha} = funded_org_wallet!(name: "alpha org co")
      {beta_org, beta} = funded_org_wallet!(name: "beta org co")

      {:ok, view, _html} = live(conn, "/admin/orgs")

      render_change(view, "search", %{"search" => %{"query" => "alpha org"}})

      assert has_element?(view, "[data-testid='admin-orgs-org-#{alpha.id}']")
      refute has_element?(view, "[data-testid='admin-orgs-org-#{beta.id}']")

      # The slug is the org's address: the other way in.
      render_change(view, "search", %{"search" => %{"query" => beta_org.slug}})

      assert has_element?(view, "[data-testid='admin-orgs-org-#{beta.id}']")
      refute has_element?(view, "[data-testid='admin-orgs-org-#{alpha.id}']")

      # Clearing the search hands the whole list back, header with it.
      render_change(view, "search", %{"search" => %{"query" => ""}})
      assert has_element?(view, "[data-testid='admin-orgs-org-#{alpha.id}']")
      assert has_element?(view, "[data-testid='admin-orgs-org-#{beta.id}']")
      assert has_element?(view, "[data-testid='admin-orgs-table-header']")

      # A match-shaped string that is nobody's org: the honest empty
      # state, scoped to the seam.
      render_change(view, "search", %{"search" => %{"query" => "zzz-no-such-org"}})

      assert has_element?(
               view,
               "[data-testid='admin-orgs-list'] p",
               "No org with a wallet matches"
             )

      # A dangling header must not promise columns nothing fills.
      refute has_element?(view, "[data-testid='admin-orgs-table-header']")

      # ILIKE wildcards are literals: a bare % (which an unescaped
      # pattern would turn into match-everything) matches no org.
      render_change(view, "search", %{"search" => %{"query" => "%"}})

      assert has_element?(
               view,
               "[data-testid='admin-orgs-list'] p",
               "No org with a wallet matches"
             )
    end

    test "the list caps at the latest 100 and says so", %{conn: conn} do
      {_oldest_org, oldest} = org_wallet!()

      newest =
        for _n <- 1..100 do
          {_org, wallet} = org_wallet!()
          wallet
        end
        |> List.last()

      {:ok, view, _html} = live(conn, "/admin/orgs")

      assert has_element?(view, "[data-testid='admin-orgs-capped']", "latest 100")
      assert has_element?(view, "[data-testid='admin-orgs-org-#{newest.id}']")
      refute has_element?(view, "[data-testid='admin-orgs-org-#{oldest.id}']")
    end

    test "the list is the wallet seam: an org without a wallet renders nowhere", %{conn: conn} do
      # A team org that never touched billing has no wallet — the
      # wallet spine is the surface's meaning (wallet state per org),
      # so the row is out of this table's scope by curation, not
      # policy: the org read itself admits admins cross-org since
      # ADR-0047. The page says as much in its scope copy.
      _walletless_org =
        Organization.create!(
          %{
            name: "walletless org co",
            slug: "walletless-#{@n}-#{System.unique_integer([:positive])}"
          },
          authorize?: false
        )

      {_listed_org, listed} = funded_org_wallet!(name: "listed org co")

      {:ok, view, _html} = live(conn, "/admin/orgs")

      assert has_element?(view, "[data-testid='admin-orgs-org-#{listed.id}']")

      refute has_element?(view, "[data-testid='admin-orgs-list']", "walletless org co")

      # The scope copy names the seam's honesty.
      assert has_element?(
               view,
               "[data-testid='admin-orgs']",
               "An org appears here once its wallet exists"
             )
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/orgs")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/orgs")

      assert conn.status == 403
    end
  end
end

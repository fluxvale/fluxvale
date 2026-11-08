defmodule FluxValeWeb.AdminBillingLiveTest do
  @moduledoc false

  # The wallets surface (#501): the wallet table, its search, its cap,
  # and the negative-balance emphasis. The route gates here are the
  # shared live_session's arms (the anonymous 302 and the non-admin
  # 403, pinned once per surface); the surface's writes live on the
  # detail page and are pinned there (this surface is read-only).

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-billing-admin-#{@n}@fluxvale.com",
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

    name = Keyword.get(opts, :name, "billing org #{@n}-#{System.unique_integer([:positive])}")
    renamed = Organization.update!(org, %{name: name}, authorize?: false)

    {:ok, wallet} = Billing.ensure_wallet(renamed)
    {renamed, wallet}
  end

  defp funded_wallet!(opts) do
    {org, wallet} = org_wallet!(opts)
    cents = Keyword.get(opts, :balance_cents, 10_000)

    if cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, cents, reason: :adjustment)
    end

    {org, wallet}
  end

  # The precondition's flip rides the admin policy with a minted admin
  # actor (the seeds posture — the policy is what the detail suite
  # pins; the fixtures here just need the state).
  defp waived_wallet!(opts) do
    admin = admin_actor!()
    {org, wallet} = funded_wallet!(opts)
    {:ok, waived} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin)
    {org, waived}
  end

  # A wallet below zero, anchored by the sweep's own write posture (the
  # ladder markers are states actions cannot produce — the sweep tests
  # use the same escape).
  defp negative_wallet!(opts) do
    {org, wallet} = funded_wallet!(Keyword.merge(opts, balance_cents: 500))
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

  defp admin_actor! do
    User.create!(
      "admin-billing-fixture-#{@n}-#{System.unique_integer([:positive])}@fluxvale.com",
      %{platform_role: :admin},
      authorize?: false
    )
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "the wallet table" do
    test "lists every wallet org-first with its balance, waiver state, and the open link", %{
      conn: conn
    } do
      {plain_org, plain} = funded_wallet!(name: "plain co")
      {waived_org, waived} = waived_wallet!(name: "waived co")
      {negative_org, negative} = negative_wallet!(name: "negative co")

      {:ok, view, _html} = live(conn, "/admin/billing")

      assert has_element?(view, "[data-testid='admin-billing']")

      for {org, wallet} <- [{plain_org, plain}, {waived_org, waived}, {negative_org, negative}] do
        assert text_of(view, "[data-testid='admin-billing-org-#{wallet.id}']") =~
                 org.name

        assert has_element?(
                 view,
                 "[data-testid='admin-billing-org-link-#{wallet.id}'][href='/admin/billing/wallets/#{wallet.id}']"
               )

        assert has_element?(
                 view,
                 "[data-testid='admin-billing-open-#{wallet.id}'][href='/admin/billing/wallets/#{wallet.id}']"
               )
      end

      assert text_of(view, "[data-testid='admin-billing-balance-#{plain.id}']") == "$100.00"
      assert text_of(view, "[data-testid='admin-billing-waiver-#{plain.id}']") == "Not waived"

      assert text_of(view, "[data-testid='admin-billing-balance-#{waived.id}']") == "$100.00"

      assert text_of(view, "[data-testid='admin-billing-waiver-#{waived.id}']") == "Waived"

      assert has_element?(view, "[data-testid='admin-billing-waiver-#{waived.id}'] .hero-key")

      assert text_of(view, "[data-testid='admin-billing-balance-#{negative.id}']") == "-$5.00"
    end

    test "a negative-balance row reads as attention-wanted in tone and cue", %{conn: conn} do
      {_negative_org, negative} = negative_wallet!(name: "sinking co")
      {_plain_org, plain} = funded_wallet!(name: "afloat co")

      {:ok, view, _html} = live(conn, "/admin/billing")

      # The countdown badge: tone (danger) plus the non-color cue (the
      # clock icon and the label), and the dates name the anchor AND
      # the deadline, so the countdown reads as one.
      badge = "[data-testid='admin-billing-negative-#{negative.id}']"
      assert has_element?(view, badge, "Destroy clock")
      assert has_element?(view, badge <> " .hero-clock")

      # The fixture's stored anchor, not a recomputed utc_now: the two
      # stamps are seconds apart, and a strftime across a month boundary
      # would flake the date assertions (CodeRabbit's final-head nit).
      anchored_at = negative.negative_since
      anchor = Calendar.strftime(anchored_at, "%b %d, %Y")
      deadline_at = DateTime.add(anchored_at, 30, :day)
      deadline = Calendar.strftime(deadline_at, "%b %d, %Y")
      badge_text = text_of(view, badge)
      assert badge_text =~ anchor
      assert badge_text =~ deadline
      assert badge_text =~ "deletes"

      # Positive rows carry no countdown.
      refute has_element?(view, "[data-testid='admin-billing-negative-#{plain.id}']")
    end

    test "a recovered balance with an unswept anchor shows no countdown", %{conn: conn} do
      # The sweep clears a recovered wallet's anchor hourly: until then
      # the row is armed but not a countdown, and must not read as one.
      {_org, wallet} = funded_wallet!(name: "recovered co")

      wallet
      |> Ash.Changeset.for_update(
        :set_ladder_state,
        %{negative_since: DateTime.add(DateTime.utc_now(), -1, :hour)},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/billing")

      refute has_element?(view, "[data-testid='admin-billing-negative-#{wallet.id}']")
    end

    test "negative balances pin to the top, then newest provisioned first", %{conn: conn} do
      # The oldest wallet goes negative LAST: under provisioning-time
      # order it would sink under every newer signup — the exact row
      # the surface exists to surface.
      {old_org, old} = funded_wallet!(name: "old co")
      {_mid_org, mid} = funded_wallet!(name: "mid co")
      {_new_org, new} = funded_wallet!(name: "new co")

      {:ok, _debit} = Billing.debit_wallet(old, 5_000 * 10_000)

      old
      |> Ash.Changeset.for_update(
        :set_ladder_state,
        %{negative_since: DateTime.add(DateTime.utc_now(), -1, :day)},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/billing")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#admin-billing-table > div")
        |> Enum.map(fn row ->
          row
          |> LazyHTML.query("[data-testid^='admin-billing-org-']")
          |> Enum.at(0)
          |> LazyHTML.attribute("data-testid")
          |> Enum.join("")
          |> String.replace_prefix("admin-billing-org-", "")
        end)

      # The countdown pins first; the positives keep provisioning
      # order. (The setup admin's own personal-org wallet trails.)
      assert Enum.take(ids, 3) == [old.id, new.id, mid.id]

      assert old_org
    end

    test "a negative balance with no anchor yet shows the badge without a date", %{conn: conn} do
      {_org, wallet} = funded_wallet!(name: "unanchored co", balance_cents: 500)
      {:ok, _debit} = Billing.debit_wallet(wallet, 1_000 * 10_000)

      {:ok, view, _html} = live(conn, "/admin/billing")

      # The sweep has not anchored the clock yet, so the date slot
      # beside the badge stays empty.
      badge = "[data-testid='admin-billing-negative-#{wallet.id}']"
      assert has_element?(view, badge, "Destroy clock")
      assert text_of(view, badge) == "Destroy clock"
    end

    test "search narrows the list by org name or slug and never reaches past it", %{
      conn: conn
    } do
      {_alpha_org, alpha} = funded_wallet!(name: "alpha co")
      {beta_org, beta} = funded_wallet!(name: "beta co")

      {:ok, view, _html} = live(conn, "/admin/billing")

      render_change(view, "search", %{"search" => %{"query" => "alpha"}})

      assert has_element?(view, "[data-testid='admin-billing-org-#{alpha.id}']")
      refute has_element?(view, "[data-testid='admin-billing-org-#{beta.id}']")

      # The slug is the org's address: the other way in.
      render_change(view, "search", %{"search" => %{"query" => beta_org.slug}})

      assert has_element?(view, "[data-testid='admin-billing-org-#{beta.id}']")
      refute has_element?(view, "[data-testid='admin-billing-org-#{alpha.id}']")

      # Clearing the search hands the whole list back.
      render_change(view, "search", %{"search" => %{"query" => ""}})
      assert has_element?(view, "[data-testid='admin-billing-org-#{alpha.id}']")
      assert has_element?(view, "[data-testid='admin-billing-org-#{beta.id}']")

      # A match-shaped string that is nobody's org: the honest empty state.
      render_change(view, "search", %{"search" => %{"query" => "zzz-no-such-org"}})
      assert has_element?(view, "[data-testid='admin-billing-list'] p", "No wallet matches")
    end

    test "the list caps at the latest 100 and says so", %{conn: conn} do
      {_oldest_org, oldest} = org_wallet!()

      newest =
        for _n <- 1..100 do
          {_org, wallet} = org_wallet!()
          wallet
        end
        |> List.last()

      {:ok, view, _html} = live(conn, "/admin/billing")

      assert has_element?(view, "[data-testid='admin-billing-capped']", "latest 100")
      assert has_element?(view, "[data-testid='admin-billing-capped']", "pin to the top")
      assert has_element?(view, "[data-testid='admin-billing-org-#{newest.id}']")
      refute has_element?(view, "[data-testid='admin-billing-org-#{oldest.id}']")
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/billing")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/billing")

      assert conn.status == 403
    end
  end
end

defmodule FluxValeWeb.BillingLive.TopupOrgTest do
  @moduledoc false

  # The org-context top-up (#408): the wizard mounted under
  # /organizations/:slug/billing/topup bills the URL org's wallet —
  # the not-found posture for unknown slugs and non-members, the S5
  # redirect for the personal org's slug, and the personal wizard's
  # regression (the default arm is untouched). The provider is
  # stubbed at the provider seam (the Access suite's Tailscale
  # stance), which keeps this file async — the personal suite's
  # Req-level stubs pin the :hitpay app-env block and stay
  # async: false there.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Providers.HitPay
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    user = AccountsFixtures.user!()

    # The fixture org has no JIT welcome grant, so its wallet starts
    # at exactly zero: the tests below own their arithmetic.
    org = AccountsFixtures.owned_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(org)

    %{user: user, org: org, wallet: wallet, conn: SessionHelpers.sign_in(conn, user)}
  end

  # The checkout is opened in the LiveView process, so stub (not
  # expect) and report the request through a canary message — the
  # posture the personal suite's stub comments set.
  defp stub_checkout do
    parent = self()

    stub(HitPay, :create_checkout, fn request, _opts ->
      send(parent, {:checkout_request, request})
      {:ok, %{payment_request_id: "pr_org", checkout_url: "https://checkout/pr_org"}}
    end)
  end

  # The combobox is the country's only door (the personal suite's
  # helper, verbatim idiom).
  defp select_country(view, code) do
    render_change(view, "filter-countries", %{
      "country_query" => code,
      "_target" => ["country_query"]
    })

    view
    |> element("ul#country-listbox li[phx-value-code='#{code}']")
    |> render_click(%{"code" => code})
  end

  defp walk_to_payment(conn, path) do
    {:ok, view, _html} = live(conn, path)

    select_country(view, "DE")

    view
    |> form("#topup-details-form",
      details: %{name: "Jane Doe", email: "jane@example.com"}
    )
    |> render_submit()

    view
    |> form("#topup-amount-form", amount: %{dollars: "5"})
    |> render_submit()

    view
  end

  describe "the org route — happy path" do
    test "a member tops up and the URL org's wallet is credited", %{
      conn: conn,
      user: user,
      org: org,
      wallet: wallet
    } do
      stub_checkout()

      # The actor's personal wallet is the control: whatever it holds
      # now, it must still hold after the org's top-up.
      personal = AccountsFixtures.personal_org!(user)
      {:ok, personal_wallet} = Billing.ensure_wallet(personal)
      {:ok, personal_before} = Billing.balance(personal_wallet, authorize?: false)

      view = walk_to_payment(conn, ~p"/organizations/#{org.slug}/billing/topup")

      # The wizard's chrome rides the org: back link to the org's
      # billing page, the stepper at the payment rung.
      assert has_element?(
               view,
               "a[href='/organizations/#{org.slug}/billing']",
               "← Billing"
             )

      # The copy names THIS org's wallet (the apostrophe rides HTML
      # escaping).
      assert render(view) =~ "Prepaid balance for #{org.name}&#39;s instances."

      assert has_element?(view, "#topup-pay")

      _result = render_click(view, "pay")

      # The handoff is the hosted checkout; the return rides org-scoped
      # so the gateway lands back on the org route.
      assert_redirect(view, "https://checkout/pr_org")

      assert_receive {:checkout_request, request}
      assert request.redirect_url =~ "/organizations/#{org.slug}/billing/topup/return"

      # The pending row belongs to the URL org — not the actor's
      # personal org.
      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert [%Topup{status: :pending, payment_request_id: "pr_org", amount_cents: 500}] =
               topups

      # The webhook completes it and the credit lands in the org's
      # wallet (the row is the webhook's join key).
      {:ok, _completed} =
        Billing.complete_topup(%{
          payment_request_id: "pr_org",
          payment_id: "pay_org",
          amount_cents: 500,
          idempotency_key: "hitpay:pay_org"
        })

      assert {:ok, 500} = Billing.balance(wallet, authorize?: false)

      # The actor's personal wallet never moved: the wizard billed the
      # URL org.
      assert {:ok, ^personal_before} = Billing.balance(personal_wallet, authorize?: false)
    end

    test "the gateway return lands on the org's confirmation", %{
      conn: conn,
      org: org,
      wallet: wallet
    } do
      {:ok, topup} =
        Topup.create(
          %{
            organization_id: org.id,
            amount_cents: 500,
            buyer_email: "jane@example.com",
            billing_country: "DE"
          },
          authorize?: false
        )

      {:ok, _attached} =
        Topup.attach_checkout(topup, %{payment_request_id: "pr_org"}, authorize?: false)

      {:ok, _completed} =
        Billing.complete_topup(%{
          payment_request_id: "pr_org",
          payment_id: "pay_org",
          amount_cents: 500,
          idempotency_key: "hitpay:pay_org"
        })

      {:ok, view, _html} =
        live(conn, ~p"/organizations/#{org.slug}/billing/topup/return?reference=pr_org")

      assert has_element?(view, "[data-testid='topup-confirmation-completed']")
      assert balance = render(element(view, "[data-testid='topup-confirmation-balance']"))
      assert balance =~ "#{org.name}&#39;s balance is now"
      assert balance =~ "$5.00"

      # The landing's way out is the org's billing page.
      assert has_element?(
               view,
               "a#topup-back-to-billing[href='/organizations/#{org.slug}/billing']"
             )

      assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
    end

    test "a reference from another of the actor's orgs reads as not-found on the org route", %{
      conn: conn,
      user: user,
      org: org
    } do
      # The discriminating shape (the org billing suite's posture): the
      # SAME actor belongs to two orgs, and the read policy would let
      # either org's rows through — so the fetch itself pins the URL
      # org. No flow creates a second org yet, so both rows ride the
      # actions with authorize?: false (the #279 bootstrap posture).
      other_org =
        Organization.create!(%{name: "Other Org", slug: "topup-other-org"}, authorize?: false)

      Membership.create!(%{organization_id: other_org.id, user_id: user.id, role: :owner},
        authorize?: false
      )

      {:ok, _other_wallet} = Billing.ensure_wallet(other_org)

      {:ok, topup} =
        Topup.create(
          %{
            organization_id: other_org.id,
            amount_cents: 700,
            buyer_email: "jane@example.com",
            billing_country: "DE"
          },
          authorize?: false
        )

      {:ok, _attached} =
        Topup.attach_checkout(topup, %{payment_request_id: "pr_other_org"}, authorize?: false)

      {:ok, _completed} =
        Billing.complete_topup(%{
          payment_request_id: "pr_other_org",
          payment_id: "pay_other",
          amount_cents: 700,
          idempotency_key: "hitpay:pay_other"
        })

      # The org route's return renders the not-found card — the other
      # org's charge never wears this org's chrome — and its way out is
      # THIS org's billing page.
      {:ok, view, _html} =
        live(conn, ~p"/organizations/#{org.slug}/billing/topup/return?reference=pr_other_org")

      assert has_element?(view, "[data-testid='topup-confirmation']")
      assert render(view) =~ "We couldn&#39;t find that top-up"
      # The hint names THIS organization — the reference is recognized
      # for the actor's account (it's their other org's), just not
      # this org's.
      assert render(view) =~ "wasn&#39;t recognized for this organization"

      assert has_element?(
               view,
               "a[href='/organizations/#{org.slug}/billing']",
               "Back to billing"
             )

      refute has_element?(view, "[data-testid='topup-confirmation-balance']")
    end
  end

  describe "the org route — the not-found posture" do
    test "an unknown slug is flash + redirect home — never a bare 404", %{conn: conn} do
      assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
               live(conn, ~p"/organizations/does-not-exist/billing/topup")

      assert flash["error"] == "Organization not found."
    end

    test "a non-member's slug is the same not-found arm (no enumeration)", %{
      conn: conn
    } do
      other_org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
               live(conn, ~p"/organizations/#{other_org.slug}/billing/topup")

      assert flash["error"] == "Organization not found."
    end
  end

  describe "the org route — the personal org's slug" do
    test "redirects flash-free to the personal wizard (S5)", %{conn: conn, user: user} do
      personal = AccountsFixtures.personal_org!(user)

      # The flash map is pinned: this arm's contract is flash-FREE
      # (nothing failed) — a future put_flash here must fail this test.
      assert {:error, {:live_redirect, %{to: "/billing/topup", flash: flash}}} =
               live(conn, ~p"/organizations/#{personal.slug}/billing/topup")

      assert flash == %{}
    end
  end

  describe "the personal wizard — regression (the default arm is untouched)" do
    test "a member's /billing/topup still bills the personal org", %{
      conn: conn,
      user: user,
      org: org
    } do
      stub_checkout()

      view = walk_to_payment(conn, ~p"/billing/topup")

      # The chrome stays the personal surface's: back link to /billing.
      assert has_element?(view, "a[href='/billing']", "← Billing")

      _result = render_click(view, "pay")

      assert_receive {:checkout_request, request}
      assert request.redirect_url =~ "/billing/topup/return"
      refute request.redirect_url =~ "organizations"

      # The row belongs to the personal org — never the member's other
      # org.
      personal = AccountsFixtures.personal_org!(user)

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^personal.id)
        |> Ash.read!(authorize?: false)

      assert [%Topup{status: :pending, payment_request_id: "pr_org", amount_cents: 500}] =
               topups

      org_topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert org_topups == []
    end

    test "a crafted ?slug= query param cannot mount the org frame on the personal route", %{
      conn: conn,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/billing/topup?slug=#{org.slug}")

      # The wizard that mounted is the personal one: its back link is
      # /billing, not the org's billing page.
      assert has_element?(view, "a[href='/billing']", "← Billing")
      refute has_element?(view, "a[href='/organizations/#{org.slug}/billing']")
    end

    test "a reference from another org still renders on the personal surface (today's shape)", %{
      conn: conn,
      user: user
    } do
      # The personal arm keeps its existing fetch: any actor-readable
      # reference renders. This pins the intentional asymmetry the org
      # arm introduces — tightening the personal surface is a behavior
      # change to today's flow, not this PR's to make.
      other_org =
        Organization.create!(%{name: "Other Org 2", slug: "topup-other-org-2"}, authorize?: false)

      Membership.create!(%{organization_id: other_org.id, user_id: user.id, role: :owner},
        authorize?: false
      )

      {:ok, _other_wallet} = Billing.ensure_wallet(other_org)

      {:ok, topup} =
        Topup.create(
          %{
            organization_id: other_org.id,
            amount_cents: 700,
            buyer_email: "jane@example.com",
            billing_country: "DE"
          },
          authorize?: false
        )

      {:ok, _attached} =
        Topup.attach_checkout(topup, %{payment_request_id: "pr_other_personal"},
          authorize?: false
        )

      {:ok, _completed} =
        Billing.complete_topup(%{
          payment_request_id: "pr_other_personal",
          payment_id: "pay_other_personal",
          amount_cents: 700,
          idempotency_key: "hitpay:pay_other_personal"
        })

      {:ok, view, _html} =
        live(conn, ~p"/billing/topup/return?reference=pr_other_personal")

      assert has_element?(view, "[data-testid='topup-confirmation-completed']")
      assert has_element?(view, "a#topup-back-to-billing[href='/billing']")
    end
  end
end

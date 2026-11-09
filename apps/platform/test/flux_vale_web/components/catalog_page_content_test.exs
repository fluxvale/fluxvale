defmodule FluxValeWeb.Components.CatalogPageContentTest do
  @moduledoc """
  The catalog page's generated copy (#611 S3): the benefits checklist,
  the FAQ column generators, the similar-apps shaping, and the closing
  CTA text. Pure — plain app/version-shaped maps in, render-ready
  items out; figures (rates, welcome credit) are pinned against the
  same Pricing/Accounts calls the page reads, never literals.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Accounts
  alias FluxVale.Pricing
  alias FluxValeWeb.CatalogPageContent

  @bare_app %{name: "Forgejo", file_access: false, alternatives: [], faq: []}

  # Version-shaped (the version_rates stance): every field the
  # generators read, nil where the drift shapes would carry it.
  @priced_version %{
    first_run: nil,
    oidc_callback_path: nil,
    oidc_wiring: nil,
    recommended_size: %{monthly_cents: 295},
    default_storage_gb: 0
  }
  @guidance "Open the URL and register. The first account becomes the admin."
  @guided_version Map.put(@priced_version, :first_run, %{guidance: @guidance})
  @app_faq [
    %{question: "Does SSH work?", answer: "No. Git runs over HTTPS only on every instance."}
  ]

  @generic_cost_answer "It depends on the resources you pick. Compute bills hourly from your wallet at one flat rate. Storage bills per GB and keeps billing while the app sleeps. The deploy step shows the exact figure before you confirm."

  describe "benefits/1 (plan §7.4, D8)" do
    test "a bare app carries exactly the seven platform constants, in plan order" do
      rows = CatalogPageContent.benefits(%{oidc?: false, file_access?: false})

      assert Enum.map(rows, & &1.title) == [
               "Predictable pricing",
               "Sleep by default",
               "Your data stays yours",
               "Backups to your own bucket",
               "Free HTTPS, your own domain",
               "Pinned, tested upstream versions",
               "One region, honestly"
             ]
    end

    test "an OIDC version appends the Pocket ID row after the constants" do
      rows = CatalogPageContent.benefits(%{oidc?: true, file_access?: false})

      assert length(rows) == 8
      assert Enum.at(rows, 7).title == "SSO with Pocket ID"

      assert Enum.at(rows, 7).body ==
               "Connect apps that speak OpenID Connect to your own Pocket ID."
    end

    test "a file-access app appends the WebDAV row after the constants" do
      rows = CatalogPageContent.benefits(%{oidc?: false, file_access?: true})

      assert length(rows) == 8
      assert Enum.at(rows, 7).title == "Files over WebDAV"
      assert Enum.at(rows, 7).body == "Move a library in over WebDAV, no SSH needed."
    end

    test "both declarations land, SSO first (the plan §7.4 row order)" do
      rows = CatalogPageContent.benefits(%{oidc?: true, file_access?: true})

      assert length(rows) == 9
      assert Enum.at(rows, 7).title == "SSO with Pocket ID"
      assert Enum.at(rows, 8).title == "Files over WebDAV"
    end
  end

  describe "faq_setup_items/2 (plan §7.5)" do
    test "a bare app with no versions keeps the five platform rows, all reading fallbacks" do
      items = CatalogPageContent.faq_setup_items(@bare_app, nil)

      assert Enum.map(items, & &1.question) == [
               "How do I set up Forgejo?",
               "Do I need my own server or Docker?",
               "What does Forgejo cost?",
               "Does it stop when nobody uses it?",
               "How do I back it up?"
             ]

      assert Enum.at(items, 0).answer ==
               "Deploy it and open the URL. Forgejo is ready to use out of the box."

      # No rates without a version, so the generic cost answer — no
      # figure, the deploy step owns the number.
      assert Enum.at(items, 2).answer == @generic_cost_answer
    end

    test "a version with first_run guidance answers setup with the guidance" do
      items = CatalogPageContent.faq_setup_items(@bare_app, @guided_version)

      assert Enum.at(items, 0).answer == @guidance
    end

    test "a version without first_run falls to the out-of-box constant" do
      items = CatalogPageContent.faq_setup_items(@bare_app, @priced_version)

      assert Enum.at(items, 0).answer =~ "ready to use out of the box"
    end

    test "the cost answer carries the version's computed rate, never a literal" do
      version = %{@priced_version | default_storage_gb: 10}
      rates = Pricing.version_rates(version)
      items = CatalogPageContent.faq_setup_items(@bare_app, version)
      cost = Enum.at(items, 2)

      assert cost.answer =~
               "Starts at #{Pricing.format_usd(rates.monthly_cents)}/mo at the recommended size"
    end

    test "a sizeless version (nil rates) reads the generic cost answer" do
      version = %{@priced_version | recommended_size: nil}
      items = CatalogPageContent.faq_setup_items(@bare_app, version)
      cost = Enum.at(items, 2)

      refute cost.answer =~ "/mo"
      assert cost.answer == @generic_cost_answer
    end

    test "the Pocket ID row rides the OIDC declaration, either surface" do
      callback = Map.put(@priced_version, :oidc_callback_path, "/signin-oidc")
      wiring = Map.put(@priced_version, :oidc_wiring, %{kind: :env})

      for version <- [callback, wiring] do
        items = CatalogPageContent.faq_setup_items(@bare_app, version)

        assert Enum.any?(items, &(&1.question == "Can I sign in with my Pocket ID?"))
      end

      bare_items = CatalogPageContent.faq_setup_items(@bare_app, @priced_version)

      refute Enum.any?(bare_items, &(&1.question == "Can I sign in with my Pocket ID?"))
    end

    test "the Pocket ID row links the SSO guide and stays closed" do
      version = Map.put(@priced_version, :oidc_callback_path, "/signin-oidc")
      items = CatalogPageContent.faq_setup_items(@bare_app, version)
      pocket_id = Enum.find(items, &(&1.question == "Can I sign in with my Pocket ID?"))

      assert pocket_id.link == %{href: "/docs/guides/sso", label: "Read the SSO guide"}
      assert pocket_id.open == false
    end

    test "the files row rides app.file_access, last in the column" do
      webdav_app = %{@bare_app | file_access: true}
      items = CatalogPageContent.faq_setup_items(webdav_app, @priced_version)
      files = Enum.at(items, -1)

      assert files.question == "How do I move files in?"
      assert files.answer =~ "/dav"

      bare_items = CatalogPageContent.faq_setup_items(@bare_app, @priced_version)

      refute Enum.any?(bare_items, &(&1.question == "How do I move files in?"))
    end
  end

  describe "faq_about_items/1 (plan §7.5, D11)" do
    test "the data-ownership row is present and the only one open" do
      app = %{@bare_app | alternatives: ["GitHub", "GitLab"]}
      items = CatalogPageContent.faq_about_items(app)

      assert [%{question: "Who owns the data I keep on FluxVale?"}] =
               Enum.filter(items, & &1.open)

      ownership = Enum.find(items, &(&1.question == "Who owns the data I keep on FluxVale?"))
      assert ownership.answer =~ "The platform takes no copies."
    end

    test "the platform rows always render, in plan order" do
      app = %{@bare_app | alternatives: ["GitHub", "GitLab"]}
      items = CatalogPageContent.faq_about_items(app)

      assert Enum.map(items, & &1.question) == [
               "Who owns the data I keep on FluxVale?",
               "What does Forgejo replace?",
               "Can I export my data and leave?",
               "Which region does it run in?"
             ]
    end

    test "the replace row reuses the alternatives join and drops when absent" do
      app = %{@bare_app | alternatives: ["GitHub", "GitLab"]}
      items = CatalogPageContent.faq_about_items(app)

      assert Enum.at(items, 1).answer == "An alternative to GitHub and GitLab."

      for absent <- [[], nil] do
        cleared = %{@bare_app | alternatives: absent}
        cleared_items = CatalogPageContent.faq_about_items(cleared)

        refute Enum.any?(cleared_items, &(&1.question == "What does Forgejo replace?"))
      end
    end

    test "App.faq items append after the platform rows, closed and unlinked, once" do
      app = %{@bare_app | faq: @app_faq}
      items = CatalogPageContent.faq_about_items(app)

      assert length(items) == 4

      appended = Enum.at(items, -1)
      expected = Enum.at(@app_faq, 0)
      assert appended.question == expected.question
      assert appended.answer == expected.answer
      assert appended.open == false
      assert appended.link == nil
    end

    test "a nil faq attribute is the designed absent state" do
      app = %{@bare_app | alternatives: nil, faq: nil}
      items = CatalogPageContent.faq_about_items(app)

      assert length(items) == 3
    end
  end

  describe "similar_apps/2 (plan §6.4, D6)" do
    test "excludes self, sorts by name, caps at 4" do
      apps = [
        %{id: 1, name: "Kavita"},
        %{id: 2, name: "ActualBudget"},
        %{id: 3, name: "Forgejo"},
        %{id: 4, name: "Memos"},
        %{id: 5, name: "Pocket ID"},
        %{id: 6, name: "Umami"}
      ]

      peers = CatalogPageContent.similar_apps(%{id: 3, name: "Forgejo"}, apps)

      assert Enum.map(peers, & &1.name) == ["ActualBudget", "Kavita", "Memos", "Pocket ID"]
    end

    test "a self-only category leaves no peers, the caller's browse-card case" do
      self = %{id: 1, name: "Forgejo"}

      assert CatalogPageContent.similar_apps(self, [self]) == []
    end
  end

  describe "closing_cta/1 (plan §7.6)" do
    test "the copy reads the name and the welcome credit from code" do
      copy = CatalogPageContent.closing_cta("Forgejo")
      amount = Pricing.format_usd(Accounts.welcome_grant_cents())

      assert copy.heading == "Ready to run Forgejo?"
      assert copy.sub == "New accounts start with #{amount} in welcome credit. Deploy in minutes."
      assert copy.primary == "Deploy Forgejo"
      assert copy.ghost == "Browse the catalog"
    end
  end
end

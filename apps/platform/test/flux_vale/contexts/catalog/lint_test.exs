defmodule FluxVale.Catalog.LintTest do
  @moduledoc false

  # The curation lint (#611 plan §5) — pure report semantics; the mix
  # task only prints.

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Lint
  alias FluxVale.Seeds.CatalogData

  describe "report/1 (synthetic tiers)" do
    test "an app with no curated content reports minimum, naming both gaps" do
      lines = Lint.report([entry(%{caveats: [], alternatives: []})])

      assert [
               "bare-app: minimum (missing for recommended: alternatives, caveats | missing for full parity: community_url, faq, features, in_action_intro, screenshots)",
               "1 apps: 1 minimum, 0 recommended, 0 full parity"
             ] == lines
    end

    test "an app with caveats and alternatives reports recommended" do
      lines =
        Lint.report([entry(%{caveats: ["one caveat here"], alternatives: ["SomeAlt"]})])

      assert hd(lines) ==
               "bare-app: recommended (missing for full parity: community_url, faq, features, in_action_intro, screenshots)"
    end

    test "an app with every curated field reports full parity" do
      lines =
        Lint.report([
          entry(%{
            caveats: ["one caveat here"],
            alternatives: ["SomeAlt"],
            in_action_intro: "A line under the heading.",
            community_url: "https://community.example.com",
            screenshots: [%{"src" => "/images/catalog/app/one.png", "alt" => "A shot"}],
            features: [%{"icon" => "hero-bolt", "title" => "Fast", "body" => "A body."}],
            faq: [%{"question" => "Works?", "answer" => "Yes it does."}]
          })
        ])

      assert hd(lines) == "bare-app: full parity"
      assert List.last(lines) == "1 apps: 0 minimum, 0 recommended, 1 full parity"
    end

    test "blank strings count as absent, apps sort by slug, and the summary tallies" do
      lines =
        Lint.report([
          entry(%{slug: "zeta", caveats: ["one caveat here"], alternatives: ["SomeAlt"]}),
          entry(%{
            slug: "alpha",
            caveats: ["one caveat here"],
            alternatives: [],
            in_action_intro: "",
            community_url: ""
          })
        ])

      assert Enum.at(lines, 0) =~ "alpha: minimum"
      assert Enum.at(lines, 1) =~ "zeta: recommended"
      assert List.last(lines) == "2 apps: 1 minimum, 1 recommended, 0 full parity"
    end
  end

  describe "report/1 (shipped seed data)" do
    test "every shipped app sits at recommended (#611's tier, umami at #587, vikunja at #610, docmost at #609)" do
      lines = Lint.report(CatalogData.entries())

      for slug <-
            ~w(forgejo kavita memos pocket-id vaultwarden actualbudget umami vikunja docmost) do
        assert "#{slug}: recommended (missing for full parity: community_url, faq, features, in_action_intro, screenshots)" in lines
      end

      assert List.last(lines) == "9 apps: 0 minimum, 9 recommended, 0 full parity"
    end
  end

  # The loader's normalized entry shape — apps sorted by slug by
  # report/1, absent keys read as the loader's defaults (nil/[]).
  defp entry(overrides) do
    app = Map.merge(%{slug: "bare-app"}, overrides)
    %{category: %{slug: "test"}, apps: [app]}
  end
end

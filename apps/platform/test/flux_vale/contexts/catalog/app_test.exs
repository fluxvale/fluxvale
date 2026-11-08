defmodule FluxVale.Catalog.AppTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.Identity.User

  defp category do
    Category.create!(%{name: "Media #{System.unique_integer()}", slug: "media"},
      authorize?: false
    )
  end

  defp regular_user do
    User.create!("regular-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  describe "create/2" do
    test "creates linked to a category" do
      category = category()

      assert {:ok, app} =
               App.create(
                 %{
                   name: "Kavita",
                   slug: "kavita",
                   tagline: "Reading server",
                   category_id: category.id
                 },
                 authorize?: false
               )

      assert app.category_id == category.id
      assert app.tagline == "Reading server"
    end

    test "requires a category (belongs_to allow_nil? false)" do
      assert {:error, %Ash.Error.Invalid{}} =
               App.create(%{name: "Orphan", slug: "orphan"}, authorize?: false)
    end

    test "rejects non-URL-shaped slugs and enforces unique slug/name" do
      category = category()

      assert {:error, %Ash.Error.Invalid{}} =
               App.create(%{name: "Bad", slug: "Bad Slug", category_id: category.id},
                 authorize?: false
               )

      App.create!(%{name: "Kavita", slug: "kavita", category_id: category.id}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               App.create(%{name: "Other", slug: "kavita", category_id: category.id},
                 authorize?: false
               )

      assert {:error, %Ash.Error.Invalid{}} =
               App.create(%{name: "Kavita", slug: "other", category_id: category.id},
                 authorize?: false
               )
    end

    test "bounds tagline to 140 chars" do
      category = category()

      assert {:error, %Ash.Error.Invalid{}} =
               App.create(
                 %{
                   name: "Long",
                   slug: "long",
                   category_id: category.id,
                   tagline: String.duplicate("x", 141)
                 },
                 authorize?: false
               )
    end
  end

  describe "get_by_slug/1" do
    test "fetches by slug or errors" do
      category = category()

      created =
        App.create!(%{name: "Kavita", slug: "kavita", category_id: category.id},
          authorize?: false
        )

      assert {:ok, fetched} = App.get_by_slug("kavita", authorize?: false)
      assert fetched.id == created.id

      assert {:error, _not_found} = App.get_by_slug("nope", authorize?: false)
    end
  end

  describe "policy" do
    test "any signed-in actor reads; non-admins cannot mutate" do
      category = category()

      app =
        App.create!(%{name: "Kavita", slug: "kavita", category_id: category.id},
          authorize?: false
        )

      regular = regular_user()

      assert {:ok, [_row]} = Ash.read(App, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(app, %{tagline: "no"}, actor: regular, authorize?: true)
    end
  end

  # #611 S1: the curated marketing fields — one enforcement point in
  # the types and the attribute constraints, driven here through the
  # resource's own actions.
  describe "marketing metadata (#611)" do
    test "create accepts every field and reads the typed values back" do
      category = category()
      attrs = marketing_attrs(category)
      app = App.create!(attrs, authorize?: false)

      assert app.caveats == [
               "One honest limit, plainly stated.",
               "Another honest limit, also plain."
             ]

      assert app.alternatives == ["BigHost", "OtherHost"]
      assert app.in_action_intro == "A short line under the heading."
      assert app.community_url == "https://forum.example.com"

      assert app.screenshots == [
               %{
                 src: "/images/catalog/marketapp/one.webp",
                 alt: "The main dashboard",
                 caption: nil
               }
             ]

      assert app.features == [
               %{
                 icon: "hero-archive-box",
                 title: "Repositories",
                 body: "Your own repositories, your rules."
               }
             ]

      assert app.faq == [%{question: "Does it work?", answer: "Yes, it works out of the box."}]

      # The stored row re-reads through cast_stored — the jsonb
      # round-trip holds through the resource, not just the type.
      reloaded = App.get_by_slug!("marketapp", authorize?: false)
      assert reloaded.screenshots == app.screenshots
      assert reloaded.features == app.features
      assert reloaded.faq == app.faq
    end

    test "every field defaults to its absent state when omitted" do
      app =
        App.create!(%{name: "Bare", slug: "bare", category_id: category().id}, authorize?: false)

      assert app.caveats == []
      assert app.alternatives == []
      assert app.in_action_intro == nil
      assert app.screenshots == []
      assert app.features == []
      assert app.faq == []
      assert app.community_url == nil
    end

    test "update accepts the fields and converges them" do
      category = category()
      attrs = marketing_attrs(category)
      app = App.create!(attrs, authorize?: false)

      updated =
        App.update!(app, %{caveats: ["A different honest limit, stated."]}, authorize?: false)

      assert updated.caveats == ["A different honest limit, stated."]
    end

    test "bounds caveats: max six items, each 20-280 chars" do
      base = %{name: "Cav", slug: "caveats-app", category_id: category().id}

      seven = for n <- 1..7, do: "Caveat number #{n}, long enough to pass."
      seven_attrs = Map.put(base, :caveats, seven)

      assert {:error, %Ash.Error.Invalid{}} = App.create(seven_attrs, authorize?: false)

      too_short_attrs = Map.put(base, :caveats, ["under twenty"])

      assert {:error, %Ash.Error.Invalid{}} = App.create(too_short_attrs, authorize?: false)

      too_long = String.duplicate("c", 281)
      too_long_attrs = Map.put(base, :caveats, [too_long])

      assert {:error, %Ash.Error.Invalid{}} = App.create(too_long_attrs, authorize?: false)
    end

    test "bounds alternatives: max five items, each 1-60 chars" do
      base = %{name: "Alt", slug: "alts-app", category_id: category().id}

      six = for n <- 1..6, do: "Alt#{n}"
      six_attrs = Map.put(base, :alternatives, six)

      assert {:error, %Ash.Error.Invalid{}} = App.create(six_attrs, authorize?: false)

      too_long = String.duplicate("a", 61)
      too_long_attrs = Map.put(base, :alternatives, [too_long])

      assert {:error, %Ash.Error.Invalid{}} = App.create(too_long_attrs, authorize?: false)
    end

    test "bounds in_action_intro to 160 chars" do
      base = %{name: "Intro", slug: "intro-app", category_id: category().id}
      attrs = Map.put(base, :in_action_intro, String.duplicate("i", 161))

      assert {:error, %Ash.Error.Invalid{}} = App.create(attrs, authorize?: false)
    end

    test "community_url must be one https URL token" do
      base = %{name: "Comm", slug: "comm-app", category_id: category().id}

      for url <- [
            "http://forum.example.com",
            "ftp://forum.example.com",
            # Anchored: no trailing junk after the token.
            "https://forum.example.com trailing words here"
          ] do
        attrs = Map.put(base, :community_url, url)

        assert {:error, %Ash.Error.Invalid{}} = App.create(attrs, authorize?: false)
      end
    end

    test "malformed typed lists fail the resource write, naming the field" do
      base = %{name: "Shot", slug: "shot-app", category_id: category().id}

      bad_screenshots = Map.put(base, :screenshots, [%{"src" => "/not/catalog/x.png"}])

      assert {:error, %Ash.Error.Invalid{}} = App.create(bad_screenshots, authorize?: false)

      bad_features =
        Map.put(base, :features, [%{"icon" => "hero-nope", "title" => "T", "body" => "b"}])

      assert {:error, %Ash.Error.Invalid{}} = App.create(bad_features, authorize?: false)

      bad_faq = Map.put(base, :faq, [%{"question" => "no mark", "answer" => "an answer here"}])

      assert {:error, %Ash.Error.Invalid{}} = App.create(bad_faq, authorize?: false)
    end
  end

  # The full #611 field set, valid on every axis — the happy-path
  # fixture the marketing-metadata describe builds from.
  defp marketing_attrs(category) do
    %{
      name: "MarketApp",
      slug: "marketapp",
      category_id: category.id,
      caveats: ["One honest limit, plainly stated.", "Another honest limit, also plain."],
      alternatives: ["BigHost", "OtherHost"],
      in_action_intro: "A short line under the heading.",
      screenshots: [
        %{"src" => "/images/catalog/marketapp/one.webp", "alt" => "The main dashboard"}
      ],
      features: [
        %{
          "icon" => "hero-archive-box",
          "title" => "Repositories",
          "body" => "Your own repositories, your rules."
        }
      ],
      faq: [%{"question" => "Does it work?", "answer" => "Yes, it works out of the box."}],
      community_url: "https://forum.example.com"
    }
  end
end

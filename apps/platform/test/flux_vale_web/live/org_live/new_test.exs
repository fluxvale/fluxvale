defmodule FluxValeWeb.OrganizationLive.NewTest do
  @moduledoc """
  The org creation page (#408): the switcher footer entry's target. The
  route beats the /organizations/:slug lookup, the slug hint follows the
  name live and yields to manual edits, the happy path lands on the new
  org's home with the creator as owner, and every refusal renders where
  it belongs — field-scoped for field problems, a friendly flash for the
  over-cap one.
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    user = AccountsFixtures.user!()
    {:ok, conn: SessionHelpers.sign_in(conn, user), user: user}
  end

  # The route: the literal must beat /organizations/:slug by definition
  # order — mounting THIS page, never an org lookup for the slug "new".
  test "/organizations/new mounts the creation page, not an org lookup", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    assert has_element?(view, "[data-testid='org-new-title']", "Create an Organization")
    assert has_element?(view, "#org-new-form")
    assert has_element?(view, "[data-testid='slug-preview']", "/organizations/")
  end

  test "an anonymous visit is redirected to sign-in by the live_session gate" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/organizations/new")
  end

  describe "the slug hint" do
    test "derives from the name on validate — the field and preview follow", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Acme!! Co"})
      |> render_change()

      assert has_element?(view, "[data-testid='slug-preview']", "/organizations/acme-co")
      assert slug_value(view) == "acme-co"
    end

    test "cleans punctuation and keeps digits", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "3M Labs, Ltd."})
      |> render_change()

      assert slug_value(view) == "3m-labs-ltd"
    end

    test "trims trailing hyphens and caps at 39 characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Acme Org!"})
      |> render_change()

      assert slug_value(view) == "acme-org"

      view
      |> form("#org-new-form", organization: %{name: String.duplicate("a", 45)})
      |> render_change()

      assert slug_value(view) == String.duplicate("a", 39)
    end

    test "an all-invalid name derives the empty field, not an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "!!!"})
      |> render_change()

      assert slug_value(view) == ""
    end

    test "clearing the name clears the hint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Acme Co"})
      |> render_change()

      view
      |> form("#org-new-form", organization: %{name: ""})
      |> render_change()

      assert slug_value(view) == ""
    end

    # The derivation is a HINT: a manual slug edit makes the field the
    # user's — the name stops driving it (the server's validation stays
    # the authority either way).
    test "a manual edit stops the field from following the name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Acme Co"})
      |> render_change()

      view
      |> form("#org-new-form", organization: %{slug: "custom-address"})
      |> render_change()

      assert slug_value(view) == "custom-address"

      view
      |> form("#org-new-form", organization: %{name: "Better Name"})
      |> render_change()

      assert slug_value(view) == "custom-address"
    end
  end

  test "the happy path lands on the org home with the creator as its owner", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    view
    |> form("#org-new-form", organization: %{name: "Acme Co", slug: "acme-co"})
    |> render_submit()

    assert_redirect(view, ~p"/organizations/acme-co")

    assert {:ok, org} = Organization.get_by_slug("acme-co", actor: user)

    member =
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
      |> Ash.read_one!(authorize?: false)

    assert member.role == :owner
  end

  describe "field errors render field-scoped" do
    test "a taken slug", %{conn: conn, user: user} do
      taken = AccountsFixtures.personal_org!(AccountsFixtures.user!())
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Clone", slug: taken.slug})
      |> render_submit()

      assert has_element?(view, "#org-new-form", "has already been taken")
      refute has_element?(view, "#flash-error", "limit")

      # Nothing was created — the actor still owns just their personal org.
      assert owned_count(user) == 1
    end

    test "a reserved slug", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Docs", slug: "docs"})
      |> render_submit()

      assert has_element?(view, "#org-new-form", "is reserved")
      refute has_element?(view, "#flash-error")
    end

    test "a too-long slug", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Long", slug: String.duplicate("a", 40)})
      |> render_submit()

      assert has_element?(view, "#org-new-form", "must be at most 39 characters")
    end

    test "bad slug characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Bad", slug: "under_score"})
      |> render_submit()

      assert has_element?(
               view,
               "#org-new-form",
               "must contain only lowercase alphanumeric characters and hyphens"
             )
    end

    test "a too-long name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: String.duplicate("n", 101), slug: "fits"})
      |> render_submit()

      assert has_element?(view, "#org-new-form", "must be at most 100 characters")
    end
  end

  # The cap refusal is not a field problem: it surfaces as the friendly
  # flash, and no field error pretends the slug was the issue.
  test "the cap refusal renders the friendly flash", %{conn: conn, user: user} do
    # The JIT personal org is the first owned one; 9 more make 10.
    Enum.each(1..9, fn _n -> AccountsFixtures.owned_org!(user) end)

    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    view
    |> form("#org-new-form", organization: %{name: "Over Cap", slug: "over-cap-org"})
    |> render_submit()

    assert has_element?(view, "#flash-error", "You already own 10 organizations.")
    refute has_element?(view, "#org-new-form", "has already been taken")

    assert {:error, _none} = Organization.get_by_slug("over-cap-org", authorize?: false)
  end

  # The misfire guard: an at-cap user whose submit fails a FIELD check
  # sees the field error, not the cap flash above it.
  test "an at-cap user's bad-format slug keeps the field error, no cap flash", %{
    conn: conn,
    user: user
  } do
    Enum.each(1..9, fn _n -> AccountsFixtures.owned_org!(user) end)

    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    view
    |> form("#org-new-form", organization: %{name: "Over And Bad", slug: "Not Valid!"})
    |> render_submit()

    assert has_element?(
             view,
             "#org-new-form",
             "must contain only lowercase alphanumeric characters and hyphens"
           )

    refute has_element?(view, "#flash-error", "You already own")
  end

  defp owned_count(user) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(user_id == ^user.id and role == :owner)
    |> Ash.count!(authorize?: false)
  end

  test "a validate without a name key derives nothing and breaks nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    # A crafted phx-change posts a slug but no name at all — the hint
    # derives from nothing (the nil-name clause) and the page stays up.
    render_change(view, "validate", %{"organization" => %{"slug" => ""}})

    assert slug_value(view) == ""
    assert has_element?(view, "#org-new-form")
  end

  # Reads the slug input's current value off the rendered form — no
  # value attribute on the rendered input means an empty field.
  defp slug_value(view) do
    view
    |> element("#organization_slug")
    |> render()
    |> then(fn html ->
      case Regex.run(~r/value="([^"]*)"/, html) do
        [_match, value] -> value
        _no_match -> ""
      end
    end)
  end
end

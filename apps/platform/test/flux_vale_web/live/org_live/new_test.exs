defmodule FluxValeWeb.OrganizationLive.NewTest do
  @moduledoc """
  The org creation page (#408): one input, the name. The preview line
  derives the address live on every validate — the browser patch
  regression pin — an empty derivation reads as the empty state, and
  every refusal names the fix: a taken or reserved address reads as
  adjust-the-name, the name's own problems render field-scoped, and the
  over-cap one is the friendly flash.
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

    # De-socialized v1: one input. The address is derived, never typed.
    assert has_element?(view, "[data-testid='org-new-name-input']")
    refute has_element?(view, "#organization_slug")
  end

  test "an anonymous visit is redirected to sign-in by the live_session gate" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/organizations/new")
  end

  describe "the preview line" do
    test "starts at the empty state, then derives live from the name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      assert has_element?(view, "[data-testid='slug-preview']", "Add a name to see its address.")
      refute has_element?(view, "[data-testid='slug-preview']", "/organizations/")

      view
      |> form("#org-new-form", organization: %{name: "Acme!! Co"})
      |> render_change()

      assert has_element?(view, "[data-testid='slug-preview']", "/organizations/acme-co")

      # Live: the next keystroke's validate moves the address with it —
      # the dogfooded bug's pin (typing used to leave the slug stale).
      view
      |> form("#org-new-form", organization: %{name: "Acme & Field"})
      |> render_change()

      assert has_element?(view, "[data-testid='slug-preview']", "/organizations/acme-field")
      refute has_element?(view, "[data-testid='slug-preview']", "acme-co")
    end

    test "cleans punctuation and keeps digits", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "3M Labs, Ltd."})
      |> render_change()

      assert has_element?(view, "[data-testid='slug-preview']", "/organizations/3m-labs-ltd")
    end

    test "caps the derived address at 39 characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: String.duplicate("a", 45)})
      |> render_change()

      assert has_element?(
               view,
               "[data-testid='slug-preview']",
               "/organizations/" <> String.duplicate("a", 39)
             )

      # The cap cut can land right after a hyphen — the trailing-hyphen
      # trim is what keeps the derived address submittable (38 a's + "-b"
      # cuts to a trailing "-", trimmed to 38 a's).
      view
      |> form("#org-new-form", organization: %{name: String.duplicate("a", 38) <> "-b"})
      |> render_change()

      assert has_element?(
               view,
               "[data-testid='slug-preview']",
               "/organizations/" <> String.duplicate("a", 38)
             )
    end

    test "an all-invalid name derives the empty state, not an address", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "!!!"})
      |> render_change()

      assert has_element?(view, "[data-testid='slug-preview']", "Add a name to see its address.")
      refute has_element?(view, "[data-testid='slug-preview']", "/organizations/")
    end

    test "clearing the name clears the address", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Acme Co"})
      |> render_change()

      assert has_element?(view, "[data-testid='slug-preview']", "/organizations/acme-co")

      view
      |> form("#org-new-form", organization: %{name: ""})
      |> render_change()

      assert has_element?(view, "[data-testid='slug-preview']", "Add a name to see its address.")
    end

    test "a validate without a name key derives nothing and breaks nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      # A crafted phx-change posts a slug but no name at all — the
      # derivation reads nil (the nil-name clause) and the page stays up.
      render_change(view, "validate", %{"organization" => %{"slug" => ""}})

      assert has_element?(view, "[data-testid='slug-preview']", "Add a name to see its address.")
      assert has_element?(view, "#org-new-form")
    end
  end

  test "the happy path lands on the org home with the creator as its owner", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    view
    |> form("#org-new-form", organization: %{name: "Acme Co"})
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

  describe "a refused address reads as adjust-the-name" do
    # The taken org's own name derives its own slug ("Org <n>" →
    # "org-<n>"): the page rides the same derivation, so submitting the
    # fixture name collides on the fixture address.
    test "a taken address", %{conn: conn, user: user} do
      taken = AccountsFixtures.owned_org!(AccountsFixtures.user!())
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: taken.name})
      |> render_submit()

      assert has_element?(
               view,
               "[data-testid='address-refused']",
               "That address is taken. Try a different name."
             )

      # The refused address stays visible above the line.
      assert has_element?(view, "[data-testid='slug-preview']", "/organizations/#{taken.slug}")
      refute has_element?(view, "#flash-error", "limit")

      # Nothing was created — the actor still owns just their personal org.
      assert owned_count(user) == 1
    end

    test "a reserved derived address", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Docs"})
      |> render_submit()

      assert has_element?(
               view,
               "[data-testid='address-refused']",
               "That address is taken. Try a different name."
             )

      refute has_element?(view, "#flash-error")
    end

    test "a new input clears the refusal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      view
      |> form("#org-new-form", organization: %{name: "Docs"})
      |> render_submit()

      assert has_element?(view, "[data-testid='address-refused']")

      view
      |> form("#org-new-form", organization: %{name: "Docs Site"})
      |> render_change()

      # The line described the old derivation; the new input derived a
      # new address and the line goes with it.
      refute has_element?(view, "[data-testid='address-refused']")
    end

    test "an empty derivation never claims the address is taken", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/organizations/new")

      # HTML `required` keeps a browser from this; the crafted submit
      # must land on the name's own error, not a false "taken".
      view
      |> form("#org-new-form", organization: %{name: ""})
      |> render_submit()

      refute has_element?(view, "[data-testid='address-refused']")
      assert has_element?(view, "#org-new-form", "is required")
    end
  end

  test "a too-long name renders field-scoped", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    view
    |> form("#org-new-form", organization: %{name: String.duplicate("n", 101)})
    |> render_submit()

    assert has_element?(view, "#org-new-form", "must be at most 100 characters")
    refute has_element?(view, "[data-testid='address-refused']")
  end

  # The cap refusal is not a field problem: it surfaces as the friendly
  # flash, and no adjust-the-name line pretends the address was the issue.
  test "the cap refusal renders the friendly flash", %{conn: conn, user: user} do
    # The JIT personal org is the first owned one; 9 more make 10.
    Enum.each(1..9, fn _n -> AccountsFixtures.owned_org!(user) end)

    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    view
    |> form("#org-new-form", organization: %{name: "Over Cap Org"})
    |> render_submit()

    assert has_element?(view, "#flash-error", "You already own 10 organizations.")
    refute has_element?(view, "[data-testid='address-refused']")

    assert {:error, _none} = Organization.get_by_slug("over-cap-org", authorize?: false)
  end

  # The misfire guard: an at-cap user whose submit fails a FIELD check
  # sees the field error, not the cap flash above it.
  test "an at-cap user's too-long name keeps the field error, no cap flash", %{
    conn: conn,
    user: user
  } do
    Enum.each(1..9, fn _n -> AccountsFixtures.owned_org!(user) end)

    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    view
    |> form("#org-new-form", organization: %{name: String.duplicate("n", 101)})
    |> render_submit()

    assert has_element?(view, "#org-new-form", "must be at most 100 characters")
    refute has_element?(view, "#flash-error", "You already own")
  end

  defp owned_count(user) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(user_id == ^user.id and role == :owner)
    |> Ash.count!(authorize?: false)
  end
end

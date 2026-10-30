defmodule FluxValeWeb.Components.UserMenuTest do
  @moduledoc """
  The user menu under the #285 T4 contract: the name line + glyph carry
  the username (nil → the address's local part), the email line carries
  the account's PRIMARY address. Web-level tests drive the REAL
  SetPrimaryEmail operation and assert the rendered chrome — each
  surface assertion fails if the menu reads the frozen mirror again.
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AuthCodeHelpers
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.CoreComponents

  # The panel's markup, off the whole page — the selector scopes to the
  # panel div (the same pattern org_switcher_test uses for its rows).
  defp menu_panel(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-testid="user-menu-panel"]))
    |> LazyHTML.text()
  end

  defp glyph(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-testid="user-menu-button"] span))
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "component contract" do
    test "the panel shows the username over the primary email; the glyph is the handle's initial" do
      html =
        render_component(&CoreComponents.user_menu/1,
          username: "terence",
          email: "inbox@fluxvale.test"
        )

      text = menu_panel(html)

      assert text =~ "terence"
      assert text =~ "inbox@fluxvale.test"

      # username first — the name line owns the top of the panel
      name_at = elem(:binary.match(text, "terence"), 0)
      email_at = elem(:binary.match(text, "inbox@fluxvale.test"), 0)
      assert name_at < email_at

      assert glyph(html) == "T"
    end

    test "a nil username renders the address's local part — glyph and name line" do
      html =
        render_component(&CoreComponents.user_menu/1,
          username: nil,
          email: "rollout.window@fluxvale.test"
        )

      text = menu_panel(html)
      assert text =~ "rollout.window"
      assert glyph(html) == "R"
    end

    test "an empty-string username renders the local part too" do
      html =
        render_component(&CoreComponents.user_menu/1,
          username: "",
          email: "degene@fluxvale.test"
        )

      assert menu_panel(html) =~ "degene"
      assert glyph(html) == "D"
    end

    test "emails arrive as CiStrings at the Ash boundary — the glyph still renders" do
      html =
        render_component(&CoreComponents.user_menu/1,
          username: nil,
          email: Ash.CiString.new("cistring@fluxvale.test")
        )

      assert menu_panel(html) =~ "cistring"
      assert glyph(html) == "C"
    end
  end

  describe "folded-row active state (#319)" do
    # Below sm the header links hide and these rows replace them — the
    # section's row carries the menu-appropriate active treatment:
    # aria-current + ink/bold text, never the header's hanging underline.
    defp row(html, label) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid='user-menu-panel'] a")
      |> Enum.find(fn link ->
        text =
          link
          |> LazyHTML.text()
          |> String.trim()

        text == label
      end)
    end

    defp class_of(link) do
      link
      |> LazyHTML.attribute("class")
      |> List.first()
    end

    test "the section's row is ink + bold and aria-current" do
      html =
        render_component(&CoreComponents.user_menu/1,
          username: "terence",
          email: "inbox@fluxvale.test",
          app_links: true,
          nav_section: :instances
        )

      instances = row(html, "Instances")
      assert LazyHTML.attribute(instances, "aria-current") == ["page"]

      class = class_of(instances)
      assert class =~ "font-semibold"
      assert class =~ "text-ink"
      refute class =~ "after:"
    end

    test "sibling rows keep the quiet treatment and no aria-current" do
      html =
        render_component(&CoreComponents.user_menu/1,
          username: "terence",
          email: "inbox@fluxvale.test",
          app_links: true,
          nav_section: :instances
        )

      for label <- ["Catalog", "Billing"] do
        link = row(html, label)
        assert LazyHTML.attribute(link, "aria-current") == []

        class = class_of(link)
        assert class =~ "text-ink-muted"
        refute class =~ "font-semibold"
      end
    end

    test "no section: every row stays quiet (the public chrome's posture)" do
      html =
        render_component(&CoreComponents.user_menu/1,
          username: "terence",
          email: "inbox@fluxvale.test"
        )

      billing = row(html, "Billing")
      assert LazyHTML.attribute(billing, "aria-current") == []

      class = class_of(billing)
      assert class =~ "text-ink-muted"
    end
  end

  describe "web surfaces after the REAL SetPrimaryEmail" do
    # The one fixture all surface tests ride: a signed-in user whose
    # verified secondary was promoted through the real operations —
    # AddEmail (code mailed) → VerifyEmail → SetPrimaryEmail. The mirror
    # (users.email) keeps the demoted signup address throughout.
    setup %{conn: conn} do
      user = SessionHelpers.user!()
      conn = SessionHelpers.sign_in(conn, user)

      mirror = to_string(user.email)
      promoted = "promoted-#{System.unique_integer([:positive])}@fluxvale.test"

      assert {:ok, row} = Identity.add_email(user, promoted)
      code = AuthCodeHelpers.mailbox_code()
      assert {:ok, _verified} = Identity.verify_email(user, row.id, code)
      assert {:ok, _promoted} = Identity.set_primary_email(user, row.id)

      %{user: user, conn: conn, mirror: mirror, promoted: promoted}
    end

    test "the app chrome's menu shows the primary, not the mirror", %{
      conn: conn,
      user: user,
      mirror: mirror,
      promoted: promoted
    } do
      html =
        conn
        |> get(~p"/")
        |> html_response(200)

      panel = menu_panel(html)
      assert panel =~ promoted
      assert panel =~ user.username
      # the teeth: the demoted signup address is gone from the menu
      refute panel =~ mirror
    end

    test "the public chrome's menu (/about) shows the primary, not the mirror", %{
      conn: conn,
      mirror: mirror,
      promoted: promoted
    } do
      html =
        conn
        |> get(~p"/about")
        |> html_response(200)

      panel = menu_panel(html)
      assert panel =~ promoted
      refute panel =~ mirror
    end
  end
end

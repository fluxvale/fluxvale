defmodule FluxValeWeb.OrganizationLive.InviteAcceptTest do
  @moduledoc """
  The invitation landing (slice 4 of #408, `/invitations/accept`): the
  token resolves to exactly one rendered state — the matched open
  invite shows the org and the Accept/Decline pair, the mismatch
  explains whose address it was, terminal states get their sentence,
  and Accept/Decline drive the seam (membership on accept, none on
  decline).
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  # One inviting org, one invited address, a fresh open invite — the
  # raw token read out of the mailbox (the seam's own property: it
  # exists nowhere else), signed in as the invitee.
  setup %{conn: conn} do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, _invite} = Accounts.invite_member(owner, org, invitee.email)
    token = mailbox_token!(invitee.email)

    {:ok,
     conn: SessionHelpers.sign_in(conn, invitee),
     owner: owner,
     invitee: invitee,
     token: token,
     org: org}
  end

  describe "the matched open invite" do
    test "shows the org, the invited address, and both buttons", %{
      conn: conn,
      invitee: invitee,
      token: token,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      assert has_element?(view, "[data-testid='invite-org']", org.name)
      assert has_element?(view, "[data-testid='invite-email']", to_string(invitee.email))
      assert has_element?(view, "[data-testid='invite-accept']", "Accept invitation")
      assert has_element?(view, "[data-testid='invite-decline']", "Decline")
    end

    test "Accept joins the org as :member and lands on its home", %{
      conn: conn,
      owner: owner,
      invitee: invitee,
      token: token,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      view
      |> element("[data-testid='invite-accept']")
      |> render_click()

      assert_redirect(view, ~p"/organizations/#{org.slug}")

      # The membership is real: :member of the inviting org — and the
      # join did not touch the owner's grant (the enum-axis ruling).
      assert [membership] = memberships(org, invitee)
      assert membership.role == :member
      refute invitee_is_owner?(org, invitee)
      assert owner_is_owner?(org, owner)

      # The invite row moved to accepted.
      assert {:ok, :accepted} = Accounts.resolve_invite(token)
    end

    test "Decline confirms and joins nobody", %{
      conn: conn,
      invitee: invitee,
      token: token,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      view
      |> element("[data-testid='invite-decline']")
      |> render_click()

      # One plain confirmation sentence — the page's own copy.
      assert render(view) =~ "declined the invitation"
      assert render(view) =~ org.name

      assert memberships(org, invitee) == []
      assert {:ok, :revoked} = Accounts.resolve_invite(token)
    end
  end

  describe "the mismatch arm" do
    test "a signed-in stranger reads who the invite was sent to", %{
      conn: conn,
      invitee: invitee,
      token: token
    } do
      stranger = AccountsFixtures.user!()
      stranger_conn = SessionHelpers.sign_in(conn, stranger)

      {:ok, view, _html} = live(stranger_conn, ~p"/invitations/accept?token=#{token}")

      assert has_element?(view, "[data-testid='invite-mismatch-copy']")
      assert has_element?(view, "[data-testid='invite-email']", to_string(invitee.email))
      assert render(view) =~ "Sign in with that address to accept it."

      # No buttons — a mismatched sign-in cannot act on the invite.
      refute has_element?(view, "[data-testid='invite-accept']")
      refute has_element?(view, "[data-testid='invite-decline']")
    end
  end

  describe "the raced click arms" do
    test "an accept on a window that closed elsewhere answers and does not join twice", %{
      conn: conn,
      invitee: invitee,
      token: token,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      # The invite completes elsewhere (another tab, a raced click)
      # between this page's mount and the click.
      assert {:ok, _accepted} = Accounts.accept_invite(token, invitee)

      view
      |> element("[data-testid='invite-accept']")
      |> render_click()

      assert has_element?(view, "#flash-error", "This invitation can no longer be accepted.")

      # Exactly one membership — the raced click joined nobody extra.
      assert length(memberships(org, invitee)) == 1
    end

    test "a decline on a window that closed elsewhere answers plainly", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      assert {:ok, _declined} = Accounts.decline_invite(token)

      view
      |> element("[data-testid='invite-decline']")
      |> render_click()

      assert has_element?(view, "#flash-error", "This invitation can no longer be declined.")
    end
  end

  describe "terminal states render one plain sentence" do
    test "accepted", %{conn: conn, invitee: invitee, token: token, org: org} do
      assert {:ok, _accepted} = Accounts.accept_invite(token, invitee)

      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      assert has_element?(view, "[data-testid='invite-state-copy']", "already accepted")
      assert length(memberships(org, invitee)) == 1
    end

    test "revoked", %{conn: conn, owner: owner, token: token} do
      assert {:ok, {:open, invite}} = Accounts.resolve_invite(token)
      assert {:ok, _revoked} = Accounts.revoke_invite(owner, invite)

      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      assert has_element?(view, "[data-testid='invite-state-copy']", "no longer open")
    end

    test "expired", %{conn: conn} do
      # Expiry is a state no action can produce (the expires_at default
      # is always future) — the documented seed! exception.
      token = "expired-landing-token-material"
      org = AccountsFixtures.owned_org!(AccountsFixtures.user!())
      invitee = AccountsFixtures.user!()

      Ash.Seed.seed!(MembershipInvite, %{
        organization_id: org.id,
        email: invitee.email,
        token_hash: MembershipInvite.token_hash(token),
        expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
      })

      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      assert has_element?(view, "[data-testid='invite-state-copy']", "expired")
    end

    test "an unknown token says the link is not valid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=not-a-real-token")

      assert has_element?(view, "[data-testid='invite-state-copy']", "not valid")
    end

    test "a missing token reads as an unknown link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invitations/accept")

      assert has_element?(view, "[data-testid='invite-state-copy']", "not valid")
    end
  end

  describe "the raced arms" do
    test "an invitee already in the org is told so and lands on the org home", %{
      conn: conn,
      invitee: invitee,
      token: token,
      org: org
    } do
      # The invitee joins first (the system path), the same open invite
      # stands, the click refuses as already-member — no second grant.
      Membership.create!(
        %{organization_id: org.id, user_id: invitee.id, role: :member},
        authorize?: false
      )

      {:ok, view, _html} = live(conn, ~p"/invitations/accept?token=#{token}")

      view
      |> element("[data-testid='invite-accept']")
      |> render_click()

      assert_redirect(view, ~p"/organizations/#{org.slug}")
      assert length(memberships(org, invitee)) == 1
    end
  end

  # The raw token exists only in the emailed link (the seam's own
  # property) — tests read it out of the mailbox like an invitee would.
  defp mailbox_token!(address) do
    address = to_string(address)
    assert_receive {:email, %Swoosh.Email{to: [{_, ^address}], text_body: body}}, 1000

    [token] =
      Regex.run(~r{/invitations/accept\?token=([A-Za-z0-9_-]+)}, body, capture: :all_but_first)

    token
  end

  defp memberships(org, user) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.read!(authorize?: false)
  end

  defp invitee_is_owner?(org, user) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id and role == :owner)
    |> Ash.exists?(authorize?: false)
  end

  defp owner_is_owner?(org, owner) do
    invitee_is_owner?(org, owner)
  end
end

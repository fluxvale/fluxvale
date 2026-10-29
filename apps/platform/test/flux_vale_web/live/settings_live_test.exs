defmodule FluxValeWeb.SettingsLiveTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest
  import FluxVale.TestSupport.AuthCodeHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    # The create action stamps the verified mirror row (post-T3 sessions
    # sever a user with no user_emails row — fixtures ride the action).
    user = AccountsFixtures.user!()
    {:ok, conn: SessionHelpers.sign_in(conn, user), user: user}
  end

  # -- The shell ---------------------------------------------------------

  test "renders both cards: the username form and the addresses with badges", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "[data-testid='settings-title']", "Account settings")
    assert has_element?(view, "#username-form")
    refute has_element?(view, "[data-testid='username-confirm']")

    # the mirror row: verified primary, and it is the only row
    assert has_element?(view, "[data-testid='email-row']", to_string(user.email))
    assert has_element?(view, "[class~='fv-badge']", "Primary")
    assert has_element?(view, "[class~='fv-badge']", "Verified")
    refute has_element?(view, "[class~='fv-badge']", "Pending")

    # a primary row offers no Set primary, and Remove is disabled — the
    # frozen-mirror/primary invariants mirrored as UX, not enforcement
    mirror_id = mirror_row_id(user)

    refute has_element?(view, "[data-testid='email-set-primary-#{mirror_id}']")
    assert disabled?(view, "[data-testid='email-remove-#{mirror_id}']")

    assert has_element?(view, "#add-email-form")
  end

  test "the user menu carries the settings link row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    link = render(element(view, "[data-testid='user-menu-settings']"))
    assert link =~ ~s(href="/settings")
    assert link =~ "Account settings"
  end

  # -- Username rename (the #279 confirm-step pattern) --------------------

  test "a rename arms the confirm step naming its target; confirm applies it", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#username-form", user: %{username: "brand-new-handle"})
    |> render_submit()

    assert has_element?(view, "[data-testid='username-confirm']")
    assert has_element?(view, "#username-confirm", "brand-new-handle")

    # nothing landed yet
    assert {:ok, unchanged} = reload(user)
    assert unchanged.username == user.username

    view
    |> element("[data-testid='confirm-username']")
    |> render_click()

    assert has_element?(view, "#flash-info", "Username updated.")

    assert {:ok, renamed} = reload(user)
    assert renamed.username == "brand-new-handle"

    # the chrome follows: the menu's name line AND the switcher's
    # Personal row read the new handle
    assert has_element?(view, "[data-testid='user-menu-panel']", "brand-new-handle")
    assert has_element?(view, "[data-testid='org-switcher-panel']", "Personal — brand-new-handle")
  end

  test "an invalid rename shows the field error and never arms", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#username-form", user: %{username: "Not Valid!"})
      |> render_submit()

    assert result =~ "must use only lowercase letters"
    refute has_element?(view, "[data-testid='username-confirm']")

    assert {:ok, unchanged} = reload(user)
    assert unchanged.username == user.username
  end

  test "a reserved rename is named, not armed", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#username-form", user: %{username: "admin"})
      |> render_submit()

    assert result =~ "is reserved"
    refute has_element?(view, "[data-testid='username-confirm']")
  end

  test "submitting the current username does nothing", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#username-form", user: %{username: user.username})
    |> render_submit()

    refute has_element?(view, "[data-testid='username-confirm']")
  end

  test "editing the field after arming disarms: a confirm click applies nothing", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#username-form", user: %{username: "armed-handle"})
    |> render_submit()

    assert has_element?(view, "[data-testid='username-confirm']")

    view
    |> form("#username-form", user: %{username: "edited-handle"})
    |> render_change()

    refute has_element?(view, "[data-testid='username-confirm']")

    render_click(view, "confirm-username", %{})

    assert {:ok, unchanged} = reload(user)
    assert unchanged.username == user.username
  end

  test "an invalid edit while armed disarms too", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#username-form", user: %{username: "armed-handle"})
    |> render_submit()

    assert has_element?(view, "[data-testid='username-confirm']")

    view
    |> form("#username-form", user: %{username: "Not Valid!"})
    |> render_change()

    refute has_element?(view, "[data-testid='username-confirm']")
  end

  test "a validate that still holds the armed value keeps the panel armed", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#username-form", user: %{username: "steady-handle"})
    |> render_submit()

    assert has_element?(view, "[data-testid='username-confirm']")

    view
    |> form("#username-form", user: %{username: "steady-handle"})
    |> render_change()

    assert has_element?(view, "[data-testid='username-confirm']")

    view
    |> element("[data-testid='confirm-username']")
    |> render_click()

    assert {:ok, moved} = reload(user)
    assert moved.username == "steady-handle"
  end

  test "cancel disarms, so a queued confirm click applies nothing", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#username-form", user: %{username: "cancelled-handle"})
    |> render_submit()

    assert has_element?(view, "[data-testid='username-confirm']")

    render_click(view, "cancel-username", %{})
    render_click(view, "confirm-username", %{})

    refute has_element?(view, "[data-testid='username-confirm']")
    assert {:ok, unchanged} = reload(user)
    assert unchanged.username == user.username
  end

  test "a confirm click with no armed panel is a no-op", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    # a phx-change alone never arms — a crafted confirm must not rename
    view
    |> form("#username-form", user: %{username: "never-confirmed"})
    |> render_change()

    render_click(view, "confirm-username", %{})

    assert {:ok, unchanged} = reload(user)
    assert unchanged.username == user.username
  end

  test "a uniqueness conflict renders as a friendly field error, not a crash", %{
    conn: conn,
    user: user
  } do
    # a chosen username is a state actions can't produce (the create
    # action derives, never accepts) — seed! is the sanctioned bypass
    Ash.Seed.seed!(FluxVale.Identity.User, %{
      email: "occupant-#{System.unique_integer()}@fluxvale.test",
      username: "occupied-handle"
    })

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#username-form", user: %{username: "occupied-handle"})
    |> render_submit()

    assert has_element?(view, "[data-testid='username-confirm']")

    result =
      view
      |> element("[data-testid='confirm-username']")
      |> render_click()

    assert result =~ "has already been taken"
    refute has_element?(view, "[data-testid='username-confirm']")

    assert {:ok, unchanged} = reload(user)
    assert unchanged.username == user.username
  end

  # -- Emails: add → verify → set-primary → remove ------------------------

  test "the full add → verify cycle through the real code machinery", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    address = "cycle-#{System.unique_integer()}@fluxvale.test"

    result =
      view
      |> form("#add-email-form", address: address)
      |> render_submit()

    # the copy says a sign-in code was sent — the "one proof" semantics
    assert result =~ "We sent a sign-in code to #{address}"
    assert has_element?(view, "[class~='fv-badge']", "Pending")

    assert [%{verified_at: nil} = claim] = mine_rows(user, address)
    code = mailbox_code()

    # a wrong code is named, and the claim stays pending
    wrong =
      view
      |> form("#verify-form-#{claim.id}", code: "000000")
      |> render_submit()

    assert wrong =~ "That code didn"
    assert [%{verified_at: nil}] = mine_rows(user, address)

    # the real code verifies — markup and DB state
    verified_html =
      view
      |> form("#verify-form-#{claim.id}", code: code)
      |> render_submit()

    assert verified_html =~ "Address verified."
    assert has_element?(view, "[data-testid='email-verified-#{claim.id}']")
    assert [%{verified_at: %DateTime{}}] = mine_rows(user, address)
  end

  test "set-primary flips the DB primary and demotes the mirror; the frozen mirror refuses removal at the domain",
       %{
         conn: conn,
         user: user
       } do
    address = "promote-me-#{System.unique_integer()}@fluxvale.test"
    {:ok, verified} = add_and_verify(user, address)

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> element("[data-testid='email-set-primary-#{verified.id}']")
      |> render_click()

    assert result =~ "Primary address updated."

    rows = mine_all(user)
    promoted = Enum.find(rows, &(&1.id == verified.id))
    assert promoted.is_primary

    mirror = Enum.find(rows, &(&1.address == user.email))
    refute mirror.is_primary

    # the demoted mirror is STILL frozen: its Remove renders disabled,
    # and a crafted (un-disabled) click meets the domain's refusal —
    # which layer refused: RemoveGuard, on the resource
    assert disabled?(view, "[data-testid='email-remove-#{mirror.id}']")

    refusal = render_click(view, "remove-email", %{"row_id" => mirror.id})

    assert refusal =~ "frozen into users.email"
    assert [%{id: mirror_id}] = mine_rows(user, to_string(mirror.address))
    assert mirror_id == mirror.id
  end

  test "a second verified address is removable through the UI; the last verified is not", %{
    conn: conn,
    user: user
  } do
    address = "removable-#{System.unique_integer()}@fluxvale.test"
    {:ok, row} = add_and_verify(user, address)

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> element("[data-testid='email-remove-#{row.id}']")
      |> render_click()

    assert result =~ "Address removed."
    assert [] == mine_rows(user, address)
    refute has_element?(view, "[data-testid='email-row']", address)

    # with only the frozen mirror verified, its remove stays disabled —
    # the last-verified invariant mirrored (and enforced by the domain)
    {:ok, fresh_view, _html} = live(conn, ~p"/settings")
    mirror_id = mirror_row_id(user)
    assert disabled?(fresh_view, "[data-testid='email-remove-#{mirror_id}']")
  end

  # -- Add failures -------------------------------------------------------

  test "a malformed address is named, not claimed", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#add-email-form", address: "not-an-email")
      |> render_submit()

    assert result =~ "look like an email address"
    assert [] == mine_rows(user, "not-an-email")
    refute_received {:email, %Swoosh.Email{}}
  end

  test "a LIVE claim still blocks the add, with a copy that names the loop", %{
    conn: conn,
    user: user
  } do
    address = "live-claim-#{System.unique_integer()}@fluxvale.test"
    {:ok, _claim} = Identity.add_email(user, address)
    _code = mailbox_code()

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#add-email-form", address: address)
      |> render_submit()

    assert result =~ "already claimed"
    assert length(mine_rows(user, address)) == 1
  end

  test "an EXPIRED claim (the expiry story) no longer blocks the add — even a stranger's", %{
    conn: conn
  } do
    address = "expired-claim-#{System.unique_integer()}@fluxvale.test"

    # a state no action produces: a PENDING claim older than the window
    # (created_at is a write-time stamp) — seed! is the sanctioned
    # bypass, the org-members backdate precedent. The claimant is a
    # STRANGER: the abandoned claim must not need its owner to clear it.
    Ash.Seed.seed!(UserEmail, %{
      user_id: AccountsFixtures.user!().id,
      address: address,
      is_primary: false,
      created_at: DateTime.add(DateTime.utc_now(), -UserEmail.claim_ttl_minutes(), :minute)
    })

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#add-email-form", address: address)
      |> render_submit()

    assert result =~ "We sent a sign-in code to #{address}"
    _code = mailbox_code()

    # exactly one claim — the fresh one; the expired one is superseded
    assert [%{verified_at: nil}] = mine_rows_global(address)
  end

  test "an AccessRule denial refuses the add with the door's copy and no claim", %{
    conn: conn,
    user: user
  } do
    # the user's own address must stay allowed — only the target domain
    # closes (otherwise the session gate severs the user before the page)
    AccessRule.create!(%{email: user.email}, authorize?: false)
    denied = "denied-#{System.unique_integer()}@example.com"

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#add-email-form", address: denied)
      |> render_submit()

    assert result =~ "ask an admin for access"
    assert [] == mine_rows(user, denied)
    refute_received {:email, %Swoosh.Email{}}
  end

  test "a throttled re-add shows the wait copy and leaves no claim", %{conn: conn, user: user} do
    address = "throttled-#{System.unique_integer()}@fluxvale.test"

    {:ok, claim} = Identity.add_email(user, address)
    _code = mailbox_code()
    :ok = Identity.remove_email(user, claim.id)

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#add-email-form", address: address)
      |> render_submit()

    assert result =~ "wait a minute before requesting another code"
    assert [] == mine_rows(user, address)
  end

  test "a delivery failure flashes the retry copy and leaves no claim", %{conn: conn, user: user} do
    stub(Identity, :request_auth_code, fn _email -> {:error, :delivery_failed} end)
    address = "undeliverable-#{System.unique_integer()}@fluxvale.test"

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#add-email-form", address: address)
      |> render_submit()

    assert result =~ "please wait a minute, then try again"
    assert [] == mine_rows(user, address)
  end

  # -- Verify failures ----------------------------------------------------

  test "verifying with no live code says the code expired", %{conn: conn, user: user} do
    address = "rotted-#{System.unique_integer()}@fluxvale.test"
    {:ok, claim} = Identity.add_email(user, address)
    _code = mailbox_code()

    # the code rots away (burned by a sign-in elsewhere, say) — the
    # claim is still pending but there is nothing to prove with. The
    # asserts below ("code has expired", row still pending) are the
    # proof the burn worked.
    [auth_code] = active_codes(address)
    _burned = burn(auth_code)

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#verify-form-#{claim.id}", code: "123456")
      |> render_submit()

    assert result =~ "code has expired"
    assert [%{verified_at: nil}] = mine_rows(user, address)
  end

  test "a locked-out verify says so", %{conn: conn, user: user} do
    stub(Identity, :verify_email, fn _actor, _row_id, _code -> {:error, :locked_out} end)
    claim = pending_claim!(user)

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#verify-form-#{claim.id}", code: "123456")
      |> render_submit()

    assert result =~ "Too many attempts"
  end

  test "an infra failure on verify degrades to the generic copy", %{conn: conn, user: user} do
    stub(Identity, :verify_email, fn _actor, _row_id, _code -> {:error, :row_lookup_failed} end)
    claim = pending_claim!(user)

    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      view
      |> form("#verify-form-#{claim.id}", code: "123456")
      |> render_submit()

    assert result =~ "Something went wrong"
  end

  test "verifying an already-verified row (a crafted event) says so", %{conn: conn, user: user} do
    address = "already-#{System.unique_integer()}@fluxvale.test"
    {:ok, verified} = add_and_verify(user, address)

    {:ok, view, _html} = live(conn, ~p"/settings")

    result = render_click(view, "verify-email", %{"row_id" => verified.id, "code" => "123456"})

    assert result =~ "already verified"
  end

  test "several pending claims render unique verify-input DOM ids", %{conn: conn, user: user} do
    pending_claim!(user)
    pending_claim!(user)

    {:ok, view, _html} = live(conn, ~p"/settings")

    html = render(view)

    # the shared form struct would name every row's field `id="code"` —
    # duplicate ids break the label association and LiveView patching
    refute html =~ ~s(id="code")
    assert Regex.scan(~r/id="verify-code-input-/, html) |> length() == 2
  end

  test "verifying an unknown row id reads as gone, not someone else's claim", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    result =
      render_click(view, "verify-email", %{
        "row_id" => Ash.UUIDv7.generate(),
        "code" => "123456"
      })

    assert result =~ "claim is gone"
  end

  # -- Set-primary / remove refusals ---------------------------------------

  test "promoting a PENDING row (a crafted click) meets the domain's verified-only guard", %{
    conn: conn,
    user: user
  } do
    claim = pending_claim!(user)

    {:ok, view, _html} = live(conn, ~p"/settings")

    # the button renders disabled; the crafted click is what proves the
    # disabled state is UX, not the guard
    assert disabled?(view, "[data-testid='email-set-primary-#{claim.id}']")

    result = render_click(view, "set-primary", %{"row_id" => claim.id})

    assert result =~ "must be verified before it can be made primary"
    assert [%{is_primary: false}] = mine_rows(user, to_string(claim.address))
  end

  test "promoting an unknown row id reads as gone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    result = render_click(view, "set-primary", %{"row_id" => Ash.UUIDv7.generate()})

    assert result =~ "That address is gone"
  end

  test "removing an unknown row id reads as gone", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    result = render_click(view, "remove-email", %{"row_id" => Ash.UUIDv7.generate()})

    assert result =~ "That address is gone"
  end

  test "an unformatted domain refusal degrades to the generic copy", %{conn: conn, user: user} do
    stub(Identity, :remove_email, fn _actor, _row_id ->
      {:error, %Ash.Error.Invalid{errors: []}}
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    # the frozen mirror's remove is disabled; craft the click anyway
    result = render_click(view, "remove-email", %{"row_id" => mirror_row_id(user)})

    assert result =~ "was refused"
  end

  test "an unexpected error shape also degrades to the generic copy", %{conn: conn, user: user} do
    # no current op returns a non-:not_found atom — the arm is defensive;
    # the stub is what proves the LiveView renders it as copy, not a crash
    stub(Identity, :set_primary_email, fn _actor, _row_id -> {:error, :unexpected_shape} end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    result = render_click(view, "set-primary", %{"row_id" => mirror_row_id(user)})

    assert result =~ "was refused"
  end

  # -- Non-owner denial (unreachable, not hidden) --------------------------

  test "another user's rows are unreachable: not rendered, and :not_found at the ops", %{
    conn: conn,
    user: alice
  } do
    bob = AccountsFixtures.user!()
    bob_address = "bob-only-#{System.unique_integer()}@fluxvale.test"
    {:ok, bob_row} = add_and_verify(bob, bob_address)

    {:ok, view, _html} = live(conn, ~p"/settings")

    # not hidden — absent: alice's page never renders bob's address
    refute has_element?(view, "[data-testid='email-row']", bob_address)

    # and the row id is not reachable either — every op reads :mine first
    assert {:error, :not_found} = Identity.verify_email(alice, bob_row.id, "123456")
    assert {:error, :not_found} = Identity.set_primary_email(alice, bob_row.id)
    assert {:error, :not_found} = Identity.remove_email(alice, bob_row.id)
  end

  # -- Helpers -------------------------------------------------------------

  defp reload(user), do: User.get_by_email(user.email, authorize?: false)

  defp mirror_row_id(user) do
    user
    |> mine_all()
    |> Enum.find(&(&1.address == user.email))
    |> Map.fetch!(:id)
  end

  defp mine_all(user) do
    UserEmail
    |> Ash.Query.for_read(:mine, %{}, actor: user)
    |> Ash.read!()
  end

  defp mine_rows(user, address) do
    user
    |> mine_all()
    |> Enum.filter(&(to_string(&1.address) == address))
  end

  defp mine_rows_global(address) do
    UserEmail
    |> Ash.Query.filter(address == ^address)
    |> Ash.read!(authorize?: false)
  end

  # A pending claim for the actor, through the real operation (the code
  # it mails is consumed to keep the mailbox quiet for later asserts).
  defp pending_claim!(user) do
    {:ok, claim} = Identity.add_email(user, "pending-#{System.unique_integer()}@fluxvale.test")
    _code = mailbox_code()
    claim
  end

  # The add + verify prelude, through the REAL operations and mailbox —
  # the same cycle the UI drives, as a sanctioned precondition.
  defp add_and_verify(user, address) do
    {:ok, claim} = Identity.add_email(user, address)
    code = mailbox_code()
    {:ok, verified} = Identity.verify_email(user, claim.id, code)
    {:ok, verified}
  end

  # The disabled ATTRIBUTE, not the substring — the button's class list
  # always carries Tailwind's `disabled:` variants, so a bare =~ "disabled"
  # matches enabled buttons too (the vacuous helper the teeth run caught).
  defp disabled?(view, selector) do
    Regex.match?(~r/ disabled[=>\s]/, render(element(view, selector)))
  end
end

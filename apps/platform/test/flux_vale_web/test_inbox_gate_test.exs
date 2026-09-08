defmodule FluxValeWeb.TestInboxGateTest do
  @moduledoc false

  # The config gate (ADR-0023 Am. 3): disabled, every TestInbox route is a
  # 404 — indistinguishable from absent, which is the exit criterion's
  # "route absent under prod config" (prod leaves TEST_INBOX_ENABLED
  # unset). Sync-only: it mutates the app env, which async tests reading
  # `enabled?` could observe.

  use FluxValeWeb.ConnCase, async: false

  alias FluxVale.Identity.User
  alias FluxVale.Mailer
  alias FluxVale.TestInbox

  setup do
    original = Application.get_env(:flux_vale, :test_inbox)
    disabled = Keyword.put(original || [], :enabled, false)
    Application.put_env(:flux_vale, :test_inbox, disabled)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :test_inbox)
        value -> Application.put_env(:flux_vale, :test_inbox, value)
      end
    end)

    :ok
  end

  test "GET /test-inbox is 404", %{conn: conn} do
    conn = get(conn, "/test-inbox")

    assert conn.status == 404
  end

  test "GET /test-inbox/api/mails is 404", %{conn: conn} do
    conn = get(conn, "/test-inbox/api/mails")

    assert conn.status == 404
  end

  test "GET /test-inbox/api/mails/latest is 404", %{conn: conn} do
    conn = get(conn, "/test-inbox/api/mails/latest", email: "test+gate@fluxvale.com")

    assert conn.status == 404
  end

  test "404 even with valid admin credentials: the gate runs first and reveals nothing", %{
    conn: conn
  } do
    admin =
      User.create!("gate-admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)

    {:ok, token} = User.mint_pat("gate-admin@fluxvale.com", actor: admin)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/test-inbox/api/mails")

    assert conn.status == 404
  end

  test "disabled also disables capture — test-pattern mail still delivers" do
    # The address matches the capture pattern, but the disabled TestInbox
    # must not swallow it: the configured adapter (Swoosh.Adapters.Test
    # here; Postmark on staging) still delivers.
    {:ok, _delivery} = Mailer.deliver_auth_code("test+gate@fluxvale.com", "404040")

    assert_receive {:email, %Swoosh.Email{to: [{_, "test+gate@fluxvale.com"}]}}

    assert {:error, :not_found} = TestInbox.latest_mail("test+gate@fluxvale.com")
  end
end

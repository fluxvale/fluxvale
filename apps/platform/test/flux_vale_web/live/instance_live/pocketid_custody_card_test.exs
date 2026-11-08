defmodule FluxValeWeb.InstanceLive.PocketIdCustodyCardTest do
  @moduledoc false

  # The custody card on the PocketID instance page (#597 §4.3, S2):
  # owner-only, PocketID-only, fail-closed behind :pocketid_sso_wiring
  # (no flag row = no card anywhere). The paste is verified live inside
  # the op — these pin the card's STATES, the op tests pin the
  # discipline.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.NoK8sLeaks
  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @key "test-key-not-a-real-credential"

  setup %{conn: conn} do
    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    # Instance create rides the funded-wallet gate (#124).
    BillingFixtures.funded_wallet!(org: org)
    version = InstanceFixtures.app_version!(app_slug: "pocket-id")
    instance = InstanceFixtures.instance!(version, owner)

    # The ops' cluster + PocketID seams, stubbed for every submit path.
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _d -> {:ok, %{}} end)
    stub(Secret, :delete, fn _kc, _ns, _n -> :ok end)
    stub(ApiClient, :verify_admin_key, fn _url, _key -> :ok end)
    stub(ApiClient, :list_api_keys, fn _url, _key -> {:ok, []} end)

    conn = SessionHelpers.sign_in(conn, owner)

    {:ok, conn: conn, org: org, owner: owner, instance: instance, version: version}
  end

  defp flag_on!,
    do: FeatureFlag.create!("pocketid_sso_wiring", %{enabled: true}, authorize?: false)

  defp live_show(conn, instance) do
    live(conn, ~p"/instances/#{instance.id}")
  end

  test "fail-closed: no flag row means no card, even for the owner", %{
    conn: conn,
    owner: _owner,
    instance: instance
  } do
    {:ok, view, html} = live_show(conn, instance)

    refute has_element?(view, "#pocketid-custody-card")
    refute html =~ "Sign-in with Pocket ID"
  end

  test "flag on + PocketID + owner renders the intake card", %{
    conn: conn,
    instance: instance
  } do
    flag_on!()
    {:ok, view, html} = live_show(conn, instance)

    assert has_element?(view, "[data-testid=pocketid-custody-card]")
    assert has_element?(view, "#pocketid-key-form")
    assert has_element?(view, "input[type=password]")
    refute has_element?(view, "[data-testid=pocketid-custody-state]")
    assert html =~ "Settings → API keys"
    refute_k8s_terms(html)
  end

  test "a non-PocketID instance shows nothing even with the flag on", %{
    conn: conn,
    owner: owner
  } do
    flag_on!()

    other_version = InstanceFixtures.app_version!(app_slug: "vaultwarden")
    other = InstanceFixtures.instance!(other_version, owner)

    {:ok, view, _html} = live_show(conn, other)

    refute has_element?(view, "#pocketid-custody-card")
  end

  # A plain member sees nothing (§4.3): the crown is the owner's to paste.
  test "a plain member sees nothing", %{conn: conn, org: org, instance: instance} do
    flag_on!()

    member = AccountsFixtures.user!()

    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    conn = SessionHelpers.sign_in(conn, member)
    {:ok, view, _html} = live_show(conn, instance)

    refute has_element?(view, "#pocketid-custody-card")
  end

  # The op's fence, not the card's: a member firing the event anyway
  # (a crafted or stale client) is refused by the operation itself.
  test "a member's submit is refused by the op's owner gate", %{
    conn: conn,
    org: org,
    instance: instance
  } do
    flag_on!()

    member = AccountsFixtures.user!()

    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    conn = SessionHelpers.sign_in(conn, member)
    {:ok, view, _html} = live_show(conn, instance)

    stub(ApiClient, :verify_admin_key, fn _url, _key -> flunk("the crown is the owner's") end)

    # By event name, not selector: the card (and its form) is not in a
    # member's DOM — the point is that the op's fence holds regardless.
    html =
      render_submit(view, "save-pocketid-key", %{
        "pocketid_key" => %{"api_key" => @key}
      })

    assert html =~ "Only the organization owner can manage this key"
  end

  test "paste → verified: the card flips to the verified state", %{
    conn: conn,
    instance: instance
  } do
    flag_on!()
    {:ok, view, _html} = live_show(conn, instance)

    form = element(view, "#pocketid-key-form")

    assert render_submit(form, %{"pocketid_key" => %{"api_key" => @key}}) =~
             "Admin key verified and stored."

    assert has_element?(view, "[data-testid=pocketid-custody-state]", "Verified")
    # The intake form is gone until Replace opens it.
    refute has_element?(view, "#pocketid-key-form")
    assert has_element?(view, "[data-testid=pocketid-revoke]")

    # The row exists and never carries the key (§4.3's no-read-back).
    row = PocketIdCustody.get_by_instance!(instance.id, authorize?: false)
    refute "#{inspect(row)}" =~ @key
  end

  test "a rejected paste renders the honest error and stores nothing", %{
    conn: conn,
    instance: instance
  } do
    flag_on!()

    stub(ApiClient, :verify_admin_key, fn _url, _key -> {:error, :unauthorized} end)

    {:ok, view, _html} = live_show(conn, instance)

    html =
      render_submit(element(view, "#pocketid-key-form"), %{
        "pocketid_key" => %{"api_key" => "wrong-key"}
      })

    assert html =~ "Your Pocket ID admin API key was rejected"
    assert has_element?(view, "#pocketid-key-form")

    assert {:error, _none} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)
  end

  test "an unreachable PocketID renders its own honest copy", %{
    conn: conn,
    instance: instance
  } do
    flag_on!()

    stub(ApiClient, :verify_admin_key, fn _url, _key -> {:error, :unreachable} end)

    {:ok, view, _html} = live_show(conn, instance)

    html =
      render_submit(element(view, "#pocketid-key-form"), %{
        "pocketid_key" => %{"api_key" => @key}
      })

    assert html =~ "Couldn&#39;t reach your Pocket ID"
  end

  # 403 ≠ 401 (never folded): a valid key without admin permission is
  # its own copy and its own fix.
  test "a key without admin permission says which kind of wrong", %{
    conn: conn,
    instance: instance
  } do
    flag_on!()

    stub(ApiClient, :verify_admin_key, fn _url, _key -> {:error, :forbidden} end)

    {:ok, view, _html} = live_show(conn, instance)

    html =
      render_submit(element(view, "#pocketid-key-form"), %{
        "pocketid_key" => %{"api_key" => @key}
      })

    assert html =~ "That key doesn&#39;t have admin permission"
  end

  test "a private PocketID is refused with the make-it-public copy", %{
    conn: conn,
    owner: owner,
    instance: instance
  } do
    flag_on!()

    private = InstanceFixtures.pin!(instance, exposure: :private)

    stub(ApiClient, :verify_admin_key, fn _url, _key -> flunk("no HTTP call while private") end)

    {:ok, view, _html} = live_show(conn, private)

    html =
      render_submit(element(view, "#pocketid-key-form"), %{
        "pocketid_key" => %{"api_key" => @key}
      })

    assert html =~ "Make this Pocket ID public first"
    # The owner stays readable on the private instance's page (the
    # pin! helper builds through the owner).
    assert owner.id
  end

  test "revoke returns the card to the intake state", %{conn: conn, instance: instance} do
    flag_on!()
    {:ok, view, _html} = live_show(conn, instance)

    render_submit(element(view, "#pocketid-key-form"), %{
      "pocketid_key" => %{"api_key" => @key}
    })

    html = render_click(view, "revoke-pocketid-key")
    assert html =~ "Key custody revoked."
    assert has_element?(view, "#pocketid-key-form")
    refute has_element?(view, "[data-testid=pocketid-custody-state]")

    assert {:error, _gone} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)
  end

  test "Replace reveals the intake form again over a verified state", %{
    conn: conn,
    instance: instance
  } do
    flag_on!()
    {:ok, view, _html} = live_show(conn, instance)

    render_submit(element(view, "#pocketid-key-form"), %{
      "pocketid_key" => %{"api_key" => @key}
    })

    refute has_element?(view, "#pocketid-key-form")

    render_click(view, "toggle-replace-pocketid-key")
    assert has_element?(view, "#pocketid-key-form")
  end

  # A stale view's click (another tab revoked first): the op's honest
  # nothing-to-revoke verdict, as copy.
  test "revoking with nothing stored says so", %{conn: conn, instance: instance} do
    flag_on!()
    {:ok, view, _html} = live_show(conn, instance)

    html = render_click(view, "revoke-pocketid-key")
    assert html =~ "Nothing to revoke"
  end

  test "a blank paste is answered without calling anyone", %{conn: conn, instance: instance} do
    flag_on!()
    {:ok, view, _html} = live_show(conn, instance)

    stub(ApiClient, :verify_admin_key, fn _url, _key -> flunk("nothing to verify") end)

    html =
      render_submit(element(view, "#pocketid-key-form"), %{"pocketid_key" => %{"api_key" => ""}})

    assert html =~ "Paste an admin API key first."
  end

  # The generic verdict arm: a cluster failure at the Secret write
  # surfaces as honest copy, never a crash.
  test "a storage failure renders the generic retry copy", %{conn: conn, instance: instance} do
    flag_on!()
    stub(K8s, :kubeconfig, fn _ref -> {:error, :no_cluster} end)

    {:ok, view, _html} = live_show(conn, instance)

    html =
      render_submit(element(view, "#pocketid-key-form"), %{
        "pocketid_key" => %{"api_key" => @key}
      })

    assert html =~ "Something went wrong. Try again shortly."
  end

  # The expiry branch with a date (the nicety's happy display): staged
  # row — display-only state, the op tests own the correlation.
  test "a known expiry renders the date line", %{conn: conn, org: org, instance: instance} do
    flag_on!()

    PocketIdCustody.record!(
      %{
        organization_id: org.id,
        instance_id: instance.id,
        api_key_secret_ref: "fluxvale-pocketid-custody-#{instance.id}",
        verified_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 320, :day)
      },
      authorize?: false
    )

    {:ok, view, html} = live_show(conn, instance)

    assert html =~ "The key expires"
    refute html =~ "managed in Pocket ID"
    assert has_element?(view, "[data-testid=pocketid-custody-state]", "Verified")
  end
end

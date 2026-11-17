defmodule FluxVale.Billing.Operations.SweepAutoRechargeTest do
  @moduledoc """
  The reminder sweep (#829 L2): due + never reminded → mail AND marker
  (and a failed send rolls the marker back), the fixed 24h cadence,
  recovery clears the marker, an org nobody can reach still marks once,
  and per-org isolation. Plus the L4 decision pulse: fired and
  recovered emit the reminder telemetry event, idle and rolled-back
  passes emit nothing.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Mailer
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.Telemetry

  # The reminder lane's ops pulse (#829 L4) — the event Plugins.Business
  # sums into flux_vale_billing_auto_recharge_reminder_total.
  @reminder_event [:flux_vale, :billing, :auto_recharge, :reminder]

  # The launch defaults (decision D): threshold 500¢, amount 2500¢.
  # The wallet is funded to 400¢ — below the threshold, so every test
  # that doesn't say otherwise starts DUE.
  setup do
    {org, owner} = BillingFixtures.grant_free_org!()
    setting = reminder_setting!(org, owner)
    {_org, wallet} = BillingFixtures.funded_wallet!(org: org, balance_cents: 400)

    %{org: org, owner: owner, setting: setting, wallet: wallet}
  end

  test "due + never reminded: the mail delivers AND the marker sets", %{
    org: org,
    owner: owner
  } do
    assert {:ok, %{reminded: 1}} = Billing.sweep_auto_recharge()

    address = AccountsFixtures.primary_address!(owner)

    assert_received {:email,
                     %Swoosh.Email{
                       subject: "Your FluxVale balance is below your top-up reminder threshold",
                       to: to,
                       text_body: body
                     }}

    assert [{_name, ^address}] = to
    # The link is the ORG route carrying the saved amount (2500¢ → $25).
    assert body =~ "/organizations/#{org.slug}/billing/topup?amount=25"
    # The prose names what the click buys, not just the URL param.
    assert body =~ "Top up $25 in one click"
    assert body =~ "your $5 reminder threshold"
    assert body =~ "once a day"

    assert {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.last_reminded_at != nil

    # Once per episode: an immediate re-pass stays quiet.
    assert {:ok, %{reminded: 0}} = Billing.sweep_auto_recharge()
    refute_received {:email, _email}
  end

  test "a failed send rolls the marker back — the marker cannot outlive its mail", %{
    org: org
  } do
    stub(Mailer, :deliver_auto_recharge_reminder, fn _to, _threshold_cents, _amount_cents, _url ->
      {:error, :postmark_down}
    end)

    assert {:error, "auto-recharge sweep failed for 1 org(s)"} =
             Billing.sweep_auto_recharge()

    refute_received {:email, _email}

    assert {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.last_reminded_at == nil
  end

  test "due + reminded 23h ago: the cadence holds the mail", %{org: org, setting: setting} do
    at = hours_ago(23)
    backdate_marker!(setting, at)

    assert {:ok, %{reminded: 0}} = Billing.sweep_auto_recharge()
    refute_received {:email, _email}

    assert {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert DateTime.compare(fresh.last_reminded_at, at) == :eq
  end

  test "due + reminded 25h ago: the episode re-arms", %{setting: setting} do
    backdate_marker!(setting, hours_ago(25))

    assert {:ok, %{reminded: 1}} = Billing.sweep_auto_recharge()
    assert_received {:email, _email}
  end

  test "recovery clears the marker — the next dip starts a fresh episode", %{
    org: org,
    wallet: wallet
  } do
    assert {:ok, %{reminded: 1}} = Billing.sweep_auto_recharge()
    assert_received {:email, _email}

    # topped up above the threshold
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)

    assert {:ok, %{reminded: 0, recovered: 1}} = Billing.sweep_auto_recharge()
    refute_received {:email, _email}

    assert {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.last_reminded_at == nil

    # recovered and never reminded: the pass is idle
    assert {:ok, %{reminded: 0, recovered: 0}} = Billing.sweep_auto_recharge()
  end

  test "no verified member address: the marker still sets, nothing delivers", %{
    owner: owner,
    setting: setting
  } do
    # Park the fixture org so the addressless org is the sweep's only
    # interesting row (it would otherwise mail the fixture owner).
    {:ok, _off} = AutoRechargeSetting.set(setting, %{mode: :off}, actor: owner)

    {org2, owner2} = addressless_org!()
    reminder_setting!(org2, owner2)
    BillingFixtures.funded_wallet!(org: org2, balance_cents: 400)

    # The fixture org is parked :off above, so the addressless org is
    # the sweep's only row — it marks silently: %{reminded: 1} counts
    # the marker write, and no mail exists to deliver.
    assert {:ok, %{reminded: 1}} = Billing.sweep_auto_recharge()

    # Nothing delivered — the org has no verified address to reach.
    refute_received {:email, _email}

    # ...but the marker set: the episode must not re-fire every hour
    # for an org nobody can reach.
    assert {:ok, fresh} = AutoRechargeSetting.get_by_organization(org2.id, authorize?: false)
    assert fresh.last_reminded_at != nil
  end

  test "per-org isolation: one org's mail failure doesn't stop the other's reminder", %{
    org: org_a,
    owner: owner_a
  } do
    # Promote a distinctive verified primary on org A's owner — the
    # stub trips on exactly that address.
    distinctive = "sweep-isolated-#{System.unique_integer([:positive])}@fluxvale.test"

    {:ok, row} = UserEmail.add(distinctive, %{user: owner_a}, authorize?: false)
    {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)
    {:ok, _promoted} = UserEmail.set_primary(row, actor: owner_a)

    {org_b, owner_b} = BillingFixtures.grant_free_org!()
    reminder_setting!(org_b, owner_b)
    BillingFixtures.funded_wallet!(org: org_b, balance_cents: 400)

    stub(Mailer, :deliver_auto_recharge_reminder, fn to, _threshold_cents, _amount_cents, _url ->
      if to == distinctive do
        raise "org A's send is on fire"
      else
        {:ok, %{}}
      end
    end)

    assert {:error, "auto-recharge sweep failed for 1 org(s)"} =
             Billing.sweep_auto_recharge()

    # Org B's reminder went out (the stub's delivered branch) and its
    # marker landed — the stub bypasses Swoosh, so the delivery is
    # asserted on the call log, not a mailbox message.
    deliveries = Mimic.calls(&Mailer.deliver_auto_recharge_reminder/4)
    delivered_to = Enum.map(deliveries, fn [to, _threshold, _amount, _url] -> to end)
    assert AccountsFixtures.primary_address!(owner_b) in delivered_to

    assert {:ok, fresh_b} = AutoRechargeSetting.get_by_organization(org_b.id, authorize?: false)
    assert fresh_b.last_reminded_at != nil

    # ...while org A's marker never landed.
    assert {:ok, fresh_a} = AutoRechargeSetting.get_by_organization(org_a.id, authorize?: false)
    assert fresh_a.last_reminded_at == nil
  end

  test "a non-round threshold renders exact cents in the prose (hostile F1)", %{
    owner: owner,
    setting: setting
  } do
    # 549¢ is a legal write (min 100¢); the mail must not floor it to
    # "$5" — the sweep passes cents, the mailer formats honestly.
    {:ok, _set} = AutoRechargeSetting.set(setting, %{threshold_cents: 549}, actor: owner)

    assert {:ok, %{reminded: 1}} = Billing.sweep_auto_recharge()

    assert_received {:email, %Swoosh.Email{text_body: body}}
    assert body =~ "$5.49"
    refute body =~ "your $5 reminder"
  end

  test "an org in :off mode never sweeps", %{org: org, owner: owner, setting: setting} do
    {:ok, _off} = AutoRechargeSetting.set(setting, %{mode: :off}, actor: owner)

    # The wallet is funded below the threshold — due, but not armed.
    assert {:ok, %{reminded: 0}} = Billing.sweep_auto_recharge()
    refute_received {:email, _email}

    assert {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.last_reminded_at == nil
  end

  describe "the reminder telemetry pulse (#829 L4)" do
    test "a fired reminder emits one count-1 decision", %{org: _org} do
      Telemetry.capture_events([@reminder_event])

      assert {:ok, %{reminded: 1}} = Billing.sweep_auto_recharge()

      assert_receive {:telemetry_event, @reminder_event, %{count: 1}, %{outcome: :reminded}}
    end

    test "a recovery emits the recovered decision; an idle pass emits nothing", %{
      wallet: wallet
    } do
      Telemetry.capture_events([@reminder_event])

      # Fire first, so the topped-up pass is a recovery, not an idle.
      assert {:ok, %{reminded: 1}} = Billing.sweep_auto_recharge()
      assert_receive {:telemetry_event, @reminder_event, %{count: 1}, %{outcome: :reminded}}

      # topped up above the threshold
      {:ok, _grant} = Billing.grant_credits(wallet, 10_000)

      assert {:ok, %{reminded: 0, recovered: 1}} = Billing.sweep_auto_recharge()
      assert_receive {:telemetry_event, @reminder_event, %{count: 1}, %{outcome: :recovered}}

      # Recovered and never reminded: the pass decides nothing — no event.
      assert {:ok, %{reminded: 0, recovered: 0}} = Billing.sweep_auto_recharge()
      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end

    test "a rolled-back pass emits nothing — only committed decisions count", %{org: _org} do
      Telemetry.capture_events([@reminder_event])

      stub(Mailer, :deliver_auto_recharge_reminder, fn _to,
                                                       _threshold_cents,
                                                       _amount_cents,
                                                       _url ->
        {:error, :postmark_down}
      end)

      assert {:error, "auto-recharge reminder sweep failed for 1 org(s)"} =
               Billing.sweep_auto_recharge()

      # The marker rolled back, so the decision never persisted — the
      # pulse must not have counted it.
      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end
  end

  # The owner-role write through the :set action — tests own their
  # preconditions via actions.
  defp reminder_setting!(org, owner) do
    # authorize?: false — the create is system-only by policy; this is
    # the provisioning seam's posture (bootstrap, mirroring seeds).
    {:ok, setting} = AutoRechargeSetting.create(%{organization_id: org.id}, authorize?: false)

    {:ok, set} =
      AutoRechargeSetting.set(
        setting,
        %{mode: :reminder, threshold_cents: 500, amount_cents: 2_500},
        actor: owner
      )

    set
  end

  defp backdate_marker!(setting, at) do
    # authorize?: false — :record_reminder is the sweep's system marker
    # write (actor-forbidden by policy; this mirrors the production
    # caller).
    setting
    |> Ash.Changeset.for_update(:record_reminder, %{last_reminded_at: at}, authorize?: false)
    |> Ash.update!()
  end

  defp hours_ago(hours) do
    now = DateTime.utc_now(:microsecond)
    DateTime.add(now, -hours, :hour)
  end

  # A reminder-armed org whose only member has NO address rows: the
  # actions always stamp a primary (the create mirror), so Ash.Seed.seed!
  # is the sanctioned bypass — exactly the ladder test's drifted-member
  # shape (#287: the users table carries no address).
  defp addressless_org! do
    n = System.unique_integer([:positive])

    owner = Ash.Seed.seed!(User, %{username: "addressless-#{n}"})

    org =
      Organization.create!(
        %{
          name: "Addressless",
          slug: "addressless-#{n}",
          personal_owner_id: owner.id
        },
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: owner.id, role: :owner},
      authorize?: false
    )

    {org, owner}
  end
end

defmodule FluxVale.Billing.Operations.SweepAutoRechargeChargeTest do
  @moduledoc """
  The staged charge arm (#829 S4): gate-off inertness, the lock
  boundary (the method lookup runs before the lock transaction, the
  charge after it commits), the due matrix, D3's no-method two-pass
  rule, the strikes disable, the unknown-outcome stance, the
  stale-pending reconciliation, and per-org isolation. The reminder
  arm's suite (the module above) is untouched — every provider leg
  here is Mimic-stubbed, NO live Polar call exists.
  """

  # async: false — flips the global charge-mode gate, pins the
  # payments provider, and stubs the :polar env block.
  use FluxVale.DataCase, async: false
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Billing.Topup
  alias FluxVale.Billing.WalletLock
  alias FluxVale.Mailer
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  @order_id "ord_sweep"
  @gross 2_500

  setup do
    # The staged lane's world: the gate ON (arming :auto demands it —
    # the AutoArmGate), Polar pinned, the :polar block populated.
    original_polar = Application.get_env(:flux_vale, :polar)
    original_provider = Application.get_env(:flux_vale, :payments_provider)
    original_gate = Application.get_env(:flux_vale, :auto_recharge)

    Application.put_env(:flux_vale, :polar,
      access_token: "tok",
      webhook_secret: "secret",
      server: "sandbox",
      product_id: "prod_1"
    )

    Application.put_env(:flux_vale, :payments_provider, FluxVale.Billing.Providers.Polar)
    Application.put_env(:flux_vale, :auto_recharge, charge_mode: true)

    on_exit(fn ->
      Application.put_env(:flux_vale, :polar, original_polar)
      Application.put_env(:flux_vale, :payments_provider, original_provider)
      Application.put_env(:flux_vale, :auto_recharge, original_gate)
    end)

    {org, owner} = BillingFixtures.grant_free_org!()
    setting = auto_setting!(org, owner, "cus_1")
    {_org, wallet} = BillingFixtures.funded_wallet!(org: org, balance_cents: 400)

    %{org: org, owner: owner, setting: setting, wallet: wallet}
  end

  # ── Gate-off inertness ──

  test "gate off: the charge arm never runs and the stale arm is skipped", %{org: org} do
    Application.put_env(:flux_vale, :auto_recharge, charge_mode: false)
    stale = stale_auto_row!(org, payment_request_id: nil)

    # Flunk-stubs: ANY provider leg, stale fetch, or wallet lock means
    # the staged arm ran with the gate off.
    stub(Req, :get, fn _req, opts ->
      flunk("no provider GET with the gate off: #{inspect(opts[:url])}")
    end)

    stub(Req, :post, fn _req, opts ->
      flunk("no provider POST with the gate off: #{inspect(opts[:url])}")
    end)

    stub(WalletLock, :acquire, fn _wallet -> flunk("no wallet lock with the gate off") end)

    assert {:ok, %{reminded: 0, recovered: 0, charged: 0}} = Billing.sweep_auto_recharge()

    assert %Topup{status: :pending} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  # ── The lock boundary ──

  test "the boundary: methods before the lock, the charge after it commits" do
    record_provider_legs()

    assert {:ok, %{charged: 1}} = Billing.sweep_auto_recharge()

    # The event order IS the boundary: the method lookup ran OUTSIDE any
    # transaction, the lock INSIDE its decision transaction, and both
    # charge legs OUTSIDE — no provider call ever held the lock.
    assert_received {:provider_get, {:methods, false}}
    assert_received {:lock, true}
    assert_received {:provider_post, {:draft, false}}
    assert_received {:provider_post, {:finalize, false}}
  end

  # ── The due matrix ──

  test "below the threshold: the charge fires as an :auto row the starter never credits", %{
    org: org,
    wallet: wallet
  } do
    stub_happy_charge()

    assert {:ok, %{charged: 1}} = Billing.sweep_auto_recharge()

    assert [row] = auto_rows!(org.id)
    assert row.origin == :auto
    assert row.status == :pending
    assert row.payment_request_id == @order_id
    assert row.amount_cents == 2_500

    # The starter never posts the credit (the webhook/reconciliation
    # seam does) — the balance is untouched by the charge itself.
    assert {:ok, 400} = Billing.balance(wallet, authorize?: false)
  end

  test "above the threshold: idle, nothing fires", %{org: org, wallet: wallet} do
    {:ok, _grant} = Billing.grant_credits(wallet, 200)
    stub_methods_only()

    stub(Req, :post, fn _req, opts ->
      flunk("no charge at the threshold: #{inspect(opts[:url])}")
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert auto_rows!(org.id) == []
  end

  test "balance exactly at the threshold is not due (strict <)", %{org: org, wallet: wallet} do
    # 400¢ + 100¢ = 500¢ == threshold — not below it, nothing fires.
    {:ok, _grant} = Billing.grant_credits(wallet, 100)
    stub_methods_only()

    stub(Req, :post, fn _req, opts ->
      flunk("no charge at the exact threshold: #{inspect(opts[:url])}")
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert auto_rows!(org.id) == []
  end

  test "an in-flight auto attempt blocks (at most one)", %{org: org} do
    fresh_pending_auto_row!(org)
    stub_methods_only()

    stub(Req, :post, fn _req, opts ->
      flunk("no charge with one in flight: #{inspect(opts[:url])}")
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
  end

  test "the daily cap reached blocks the third charge", %{org: org} do
    seeded_auto_row!(org, :completed, hours_ago: 1)
    seeded_auto_row!(org, :completed, hours_ago: 2)
    stub_methods_only()

    stub(Req, :post, fn _req, opts ->
      flunk("no charge at the cap: #{inspect(opts[:url])}")
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
  end

  test "a FAILED auto charge consumes a daily-cap slot too", %{org: org} do
    seeded_auto_row!(org, :completed, hours_ago: 1)
    seeded_auto_row!(org, :failed, hours_ago: 2)
    stub_methods_only()

    stub(Req, :post, fn _req, opts ->
      flunk("no charge when the cap is spent on failures: #{inspect(opts[:url])}")
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
  end

  test "the cap window is rolling — charges outside 24h don't count", %{org: org} do
    seeded_auto_row!(org, :completed, hours_ago: 25)
    seeded_auto_row!(org, :completed, hours_ago: 26)
    stub_happy_charge()

    assert {:ok, %{charged: 1}} = Billing.sweep_auto_recharge()
  end

  # ── D3: the no-method two-pass rule ──

  test "no method, pass one: the notice mail and the marker commit together", %{
    org: org,
    owner: owner
  } do
    stub_methods_only(0)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    address = AccountsFixtures.primary_address!(owner)

    assert_received {:email,
                     %Swoosh.Email{
                       subject: "FluxVale auto-recharge found no saved payment method",
                       to: to
                     }}

    assert [{_name, ^address}] = to

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.no_method_notified_at != nil
    # Pass one only notices — the lane is still armed.
    assert fresh.mode == :auto
  end

  test "no method, pass two: the disable lands with its mail", %{
    org: org,
    setting: setting
  } do
    backdate_no_method_marker!(setting, DateTime.utc_now())
    stub_methods_only(0)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    assert_received {:email, %Swoosh.Email{text_body: body}}
    # The no-method mail is honest at both passes — same copy, second
    # delivery rides the disable.
    assert body =~ "found none"

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.mode == :off
    assert fresh.disabled_reason == :no_method
    # The disable clears the notice marker (the two-pass cycle re-arms
    # fresh on a re-arm).
    assert is_nil(fresh.no_method_notified_at)
  end

  test "a failed notice send rolls the marker back — it cannot outlive its mail", %{
    org: org
  } do
    stub_methods_only(0)
    stub(Mailer, :deliver_auto_recharge_no_method, fn _to -> {:error, :postmark_down} end)

    assert {:error, "auto-recharge sweep failed for 1 org(s)"} =
             Billing.sweep_auto_recharge()

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert is_nil(fresh.no_method_notified_at)
  end

  test "a method appearing: the charge succeeds and clears the notice marker", %{
    setting: setting
  } do
    backdate_no_method_marker!(setting, DateTime.utc_now())
    stub_happy_charge()

    assert {:ok, %{charged: 1}} = Billing.sweep_auto_recharge()

    {:ok, fresh} =
      AutoRechargeSetting.get_by_organization(setting.organization_id, authorize?: false)

    assert is_nil(fresh.no_method_notified_at)
    assert fresh.mode == :auto
  end

  test "a drifted row (armed with no stored customer) rides the no-method flow", %{
    org: org,
    setting: setting
  } do
    # The drift: the customer reference is gone while the row is armed.
    # authorize?: false — the system write mirrors the save-method seam.
    setting
    |> Ash.Changeset.for_update(:set_method_status, %{provider_customer_id: nil},
      authorize?: false
    )
    |> Ash.update!()

    # Flunk-stub: the drift must not reach the provider (there is no
    # customer id to look up).
    stub(Req, :get, fn _req, opts ->
      flunk("no provider lookup without a stored customer: #{inspect(opts[:url])}")
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    assert_received {:email,
                     %Swoosh.Email{
                       subject: "FluxVale auto-recharge found no saved payment method"
                     }}

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.no_method_notified_at != nil
  end

  # ── Strikes (decision F) ──

  test "a decline below the strikes threshold counts, no disable", %{
    org: org,
    setting: setting
  } do
    strike_count!(setting, 1)
    stub_happy_charge(declined_finalize())

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    refute_received {:email, %Swoosh.Email{subject: "Your FluxVale auto-recharge was turned off"}}

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    # Re-read the counter S3 wrote: 1 + 1 = 2 < 3 strikes.
    assert fresh.consecutive_failures == 2
    assert fresh.mode == :auto
  end

  test "a decline at the strikes threshold disables with the one-click mail", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    strike_count!(setting, 2)
    stub_happy_charge(declined_finalize())

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    address = AccountsFixtures.primary_address!(owner)

    assert_received {:email,
                     %Swoosh.Email{
                       subject: "Your FluxVale auto-recharge was turned off",
                       to: to,
                       text_body: body
                     }}

    assert [{_name, ^address}] = to
    # The disable mail carries the reminder's one-click shape (the org
    # route with the saved amount pre-filled: 2500¢ → $25).
    assert body =~ "/organizations/#{org.slug}/billing/topup?amount=25"

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.mode == :off
    assert fresh.disabled_reason == :declines
    # The disable resets the episode.
    assert fresh.consecutive_failures == 0
  end

  test "a failed disable send rolls the disable back — the lane stays armed", %{
    org: org,
    setting: setting
  } do
    strike_count!(setting, 2)
    stub_happy_charge(declined_finalize())
    stub(Mailer, :deliver_auto_recharge_disabled, fn _to, _url -> {:error, :postmark_down} end)

    assert {:error, "auto-recharge sweep failed for 1 org(s)"} =
             Billing.sweep_auto_recharge()

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    # Both-or-neither: the mail never went out, so the disable never
    # landed and the counted strike stands for the next pass.
    assert fresh.mode == :auto
    assert fresh.consecutive_failures == 3
  end

  # ── Unknown / unwritable outcomes ──

  test "an unknown outcome never counts a strike and leaves the row to the stale arm", %{
    org: org
  } do
    stub_methods_only()

    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/"
      {:ok, %Req.Response{status: 200, body: %{"id" => @order_id, "subtotal_amount" => @gross}}}
    end)

    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}/finalize"
      {:error, %Req.TransportError{reason: :econnrefused}}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    assert [row] = auto_rows!(org.id)
    assert row.status == :pending
    assert row.payment_request_id == @order_id

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.consecutive_failures == 0
    assert fresh.mode == :auto
  end

  test "a draft-leg failure leaves the row pending WITHOUT an order id, unstruck", %{
    org: org
  } do
    stub_methods_only()

    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/"
      {:error, %Req.TransportError{reason: :econnrefused}}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    assert [row] = auto_rows!(org.id)
    assert row.status == :pending
    assert is_nil(row.payment_request_id)

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.consecutive_failures == 0
  end

  test "an attach failure leaves the row pending, unstruck", %{org: org} do
    stub_methods_only()
    stub_draft()

    expect(Topup, :attach_checkout, 1, fn _topup, _attrs, _opts -> {:error, :db_hiccup} end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    assert [row] = auto_rows!(org.id)
    assert row.status == :pending

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.consecutive_failures == 0
  end

  test "a row settled mid-flight counts nothing (S3's racer wins)", %{org: org} do
    stub_methods_only()
    stub_draft()
    stub_finalize(declined_finalize())

    # The racer settles the row between the attach and the decline
    # transaction (the precondition the flow cannot produce on its own
    # — the S3 test's trick).
    expect(Topup, :attach_checkout, 1, fn topup, attrs, opts ->
      {:ok, attached} = Mimic.call_original(Topup, :attach_checkout, [topup, attrs, opts])
      {:ok, _failed} = Topup.mark_failed(attached, %{}, authorize?: false)
      {:ok, attached}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.consecutive_failures == 0
    assert fresh.mode == :auto
  end

  test "a charge-side DB failure fails the org without striking", %{org: org} do
    stub_methods_only()
    stub_draft()
    stub_finalize(declined_finalize())

    expect(Ash, :bulk_update, 1, fn _query, :mark_failed, _inputs, _opts ->
      %Ash.BulkResult{status: :error, errors: :db_down}
    end)

    assert {:error, "auto-recharge sweep failed for 1 org(s)"} =
             Billing.sweep_auto_recharge()

    {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.consecutive_failures == 0
  end

  test "a gate flip mid-pass skips the org instead of failing it", %{org: org} do
    # Calls, in order: the stale-arm gate, the charge-arm gate, then
    # StartAutoRecharge's own check — the last one sees the gate OFF
    # (the config race the warning skip is for).
    calls = :counters.new(1, [:atomics])

    stub(Billing, :auto_recharge_charge_mode?, fn ->
      :counters.add(calls, 1, 1)
      :counters.get(calls, 1) < 3
    end)

    stub_methods_only()

    stub(Req, :post, fn _req, opts ->
      flunk("no provider call on a refused lane: #{inspect(opts[:url])}")
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert auto_rows!(org.id) == []
  end

  # ── Per-org isolation (the charge arm) ──

  test "a method-lookup failure fails the org — the job retries the hour", %{org: org} do
    stub(Req, :get, fn _req, _opts -> {:error, %Req.TransportError{reason: :timeout}} end)

    assert {:error, "auto-recharge sweep failed for 1 org(s)"} =
             Billing.sweep_auto_recharge()

    # The decision was never reached — no row exists.
    assert auto_rows!(org.id) == []
  end

  test "per-org isolation: one org's provider failure never blocks the other's charge", %{
    org: org_a
  } do
    {org_b, owner_b} = BillingFixtures.grant_free_org!()
    auto_setting!(org_b, owner_b, "cus_b")
    BillingFixtures.funded_wallet!(org: org_b, balance_cents: 400)

    stub(Req, :get, fn _req, opts ->
      case opts[:url] do
        "/v1/customers/cus_1/payment-methods" ->
          raise "org A's provider call is on fire"

        "/v1/customers/cus_b/payment-methods" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"items" => [%{"id" => "pm_b", "is_default" => true}]}
           }}

        other ->
          flunk("unexpected provider GET #{inspect(other)}")
      end
    end)

    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/"
      {:ok, %Req.Response{status: 200, body: %{"id" => "ord_b", "subtotal_amount" => 2_500}}}
    end)

    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/ord_b/finalize"

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => "ord_b", "status" => "paid", "subtotal_amount" => 2_500}
       }}
    end)

    assert {:error, "auto-recharge sweep failed for 1 org(s)"} =
             Billing.sweep_auto_recharge()

    # Org B charged through; org A has no rows (its lookup never got
    # that far).
    assert [%Topup{origin: :auto, payment_request_id: "ord_b"}] = auto_rows!(org_b.id)
    assert auto_rows!(org_a.id) == []
  end

  # ── The stale-pending reconciliation arm ──

  test "stale, no order id: the draft leg never ran — failed", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: nil)

    stub(Req, :get, fn _req, opts ->
      flunk("no fetch for an id-less row: #{inspect(opts[:url])}")
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :failed} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  test "stale, paid order: credited once through the polar:<order_id> key", %{
    org: org,
    owner: owner,
    setting: setting,
    wallet: wallet
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: @order_id)

    stub(Req, :get, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}"

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => @order_id, "status" => "paid", "subtotal_amount" => @gross}
       }}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :completed} = Topup.get_by_id!(stale.id, authorize?: false)

    credited = 400 + @gross

    assert {:ok, ^credited} = Billing.balance(wallet, authorize?: false)

    # The next pass finds nothing pending — no second credit.
    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert {:ok, ^credited} = Billing.balance(wallet, authorize?: false)
  end

  test "stale, still draft: an unfinalized draft can never charge — failed", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: @order_id)

    stub(Req, :get, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}"

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => @order_id, "status" => "draft", "subtotal_amount" => @gross}
       }}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :failed} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  test "stale, gateway fault: the row stays pending for the next pass", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: @order_id)

    stub(Req, :get, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}"
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :pending} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  test "stale, a 404: never fail a possibly-charged row on an untrusted answer", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: @order_id)

    stub(Req, :get, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}"
      {:ok, %Req.Response{status: 404, body: %{"detail" => "not found"}}}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :pending} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  test "stale, paid without a usable amount: the webhook owns it — the row stays pending", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: @order_id)

    stub(Req, :get, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}"
      {:ok, %Req.Response{status: 200, body: %{"id" => @order_id, "status" => "paid"}}}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :pending} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  test "a poison stale row fails the pass but not the reminder fleet", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    # The fixture org rides the REMINDER lane this pass; the poison
    # stale row lives on a second, setting-less org.
    {:ok, _reminder} =
      Billing.set_auto_recharge_setting(setting, %{mode: :reminder}, actor: owner)

    {org_b, _owner_b} = BillingFixtures.grant_free_org!()
    poison = stale_auto_row!(org_b, payment_request_id: @order_id)

    stub(Req, :get, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}"
      raise "org B's provider call is on fire"
    end)

    assert {:error, "auto-recharge sweep failed for 1 org(s)"} = Billing.sweep_auto_recharge()

    # The reminder arm still served its org — the poison row never
    # touched it.
    assert_received {:email, %Swoosh.Email{text_body: body}}
    assert body =~ "reminder threshold"

    # The poison row stays pending for the next pass (logged, skipped).
    assert %Topup{status: :pending} = Topup.get_by_id!(poison.id, authorize?: false)
  end

  test "a racer settling the stale row mid-flip loses (terminal-once)", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: nil)

    stub(Req, :get, fn _req, opts ->
      flunk("no fetch for an id-less row: #{inspect(opts[:url])}")
    end)

    expect(Ash, :bulk_update, 1, fn _query, :mark_failed, _inputs, _opts ->
      # The racer already flipped the row terminal — zero records.
      %Ash.BulkResult{status: :success, records: []}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :pending} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  test "a failed stale bulk write leaves the row for the next pass", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: nil)

    stub(Req, :get, fn _req, opts ->
      flunk("no fetch for an id-less row: #{inspect(opts[:url])}")
    end)

    expect(Ash, :bulk_update, 1, fn _query, :mark_failed, _inputs, _opts ->
      %Ash.BulkResult{status: :error, errors: :db_down}
    end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :pending} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  test "a row completed between the stale query and the fetch answers settled", %{
    org: org,
    owner: owner,
    setting: setting
  } do
    park_setting!(setting, owner)
    stale = stale_auto_row!(org, payment_request_id: @order_id)

    stub(Billing, :reconcile_topup, fn _id, :order -> {:ok, :already_completed} end)

    assert {:ok, %{charged: 0}} = Billing.sweep_auto_recharge()
    assert %Topup{status: :pending} = Topup.get_by_id!(stale.id, authorize?: false)
  end

  # ── Fixtures ──

  # {org, setting} armed exactly as the S2 machinery produces (the S3
  # test's shape): the system write records the saved method, the
  # owner-role :set arms :auto.
  defp auto_setting!(org, owner, customer_id) do
    {:ok, bare} = AutoRechargeSetting.create(%{organization_id: org.id}, authorize?: false)

    {:ok, attached} =
      bare
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :attached,
        provider_customer_id: customer_id
      })
      |> Ash.update(authorize?: false)

    {:ok, set} = Billing.set_auto_recharge_setting(attached, %{mode: :auto}, actor: owner)
    set
  end

  # The fixture org's setting back to :off, so a stale-reconciliation
  # test exercises ONLY the stale arm.
  defp park_setting!(setting, owner) do
    {:ok, _off} = Billing.set_auto_recharge_setting(setting, %{mode: :off}, actor: owner)
  end

  # A stale :auto pending row is a state no action can produce
  # (created_at is a write-time stamp) — the sanctioned Ash.seed! case
  # (the expire_stale_topups_test posture).
  defp stale_auto_row!(org, extra) do
    Ash.Seed.seed!(
      Topup,
      Map.merge(
        %{
          organization_id: org.id,
          amount_cents: 2_500,
          origin: :auto,
          created_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second),
          updated_at: DateTime.utc_now()
        },
        Map.new(extra)
      )
    )
  end

  # A terminal :auto row at a given age — row + credit split across
  # the webhook seam, so no action produces this in one step: the
  # sanctioned Ash.seed! case. `status` is :completed or :failed (both
  # consume a daily-cap slot — the cap counts CHARGES).
  defp seeded_auto_row!(org, status, hours_ago: hours) do
    n = System.unique_integer([:positive])

    Ash.Seed.seed!(Topup, %{
      organization_id: org.id,
      amount_cents: 2_500,
      origin: :auto,
      status: status,
      payment_id: "pay_cap_#{n}",
      payment_request_id: "ord_cap_#{n}",
      created_at: DateTime.add(DateTime.utc_now(), -hours * 3600, :second),
      updated_at: DateTime.utc_now()
    })
  end

  # A FRESH in-flight auto attempt (the actions' own path — inside the
  # stale window, so only the in-flight guard sees it).
  defp fresh_pending_auto_row!(org) do
    {:ok, row} =
      Topup.create(%{organization_id: org.id, amount_cents: 2_500, origin: :auto},
        authorize?: false
      )

    {:ok, _attached} =
      Topup.attach_checkout(row, %{payment_request_id: "ord_inflight"}, authorize?: false)
  end

  defp strike_count!(setting, count) do
    # authorize?: false — the strike state mirrors what S3's operation
    # wrote on earlier passes (:record_attempt_outcome, the system
    # write, actor-forbidden by policy).
    setting
    |> Ash.Changeset.for_update(:record_attempt_outcome, %{consecutive_failures: count},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp backdate_no_method_marker!(setting, at) do
    # authorize?: false — the notice marker is the sweep's own system
    # write (:record_no_method_notice, actor-forbidden by policy).
    setting
    |> Ash.Changeset.for_update(:record_no_method_notice, %{no_method_notified_at: at},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp auto_rows!(organization_id) do
    # System read — mirrors the sweep's actorless reads.
    Topup
    |> Ash.Query.filter(organization_id == ^organization_id and origin == :auto)
    |> Ash.read!(authorize?: false)
  end

  # The boundary's evidence: every provider leg records whether a
  # transaction was open while it ran.
  defp record_provider_legs do
    stub(WalletLock, :acquire, fn wallet ->
      send(self(), {:lock, FluxVale.Repo.in_transaction?()})
      Mimic.call_original(WalletLock, :acquire, [wallet])
    end)

    stub(Req, :get, fn _req, opts ->
      assert opts[:url] == "/v1/customers/cus_1/payment-methods"
      send(self(), {:provider_get, {:methods, FluxVale.Repo.in_transaction?()}})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"items" => [%{"id" => "pm_1", "is_default" => true}]}
       }}
    end)

    stub(Req, :post, fn _req, opts ->
      leg =
        case opts[:url] do
          "/v1/orders/" -> :draft
          "/v1/orders/#{@order_id}/finalize" -> :finalize
          other -> flunk("unexpected provider POST #{inspect(other)}")
        end

      send(self(), {:provider_post, {leg, FluxVale.Repo.in_transaction?()}})

      case leg do
        :draft ->
          {:ok,
           %Req.Response{status: 200, body: %{"id" => @order_id, "subtotal_amount" => @gross}}}

        :finalize ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"id" => @order_id, "status" => "paid", "subtotal_amount" => @gross}
           }}
      end
    end)
  end

  defp stub_happy_charge(finalize \\ nil) do
    stub_methods_only()
    stub_draft()
    stub_finalize(finalize || paid_finalize())
  end

  defp stub_methods_only(count \\ 1) do
    items =
      if count == 0 do
        []
      else
        [%{"id" => "pm_1", "is_default" => true}]
      end

    stub(Req, :get, fn _req, opts ->
      assert opts[:url] == "/v1/customers/cus_1/payment-methods"
      {:ok, %Req.Response{status: 200, body: %{"items" => items}}}
    end)
  end

  defp stub_draft do
    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/"
      {:ok, %Req.Response{status: 200, body: %{"id" => @order_id, "subtotal_amount" => @gross}}}
    end)
  end

  defp stub_finalize(outcome) do
    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}/finalize"
      outcome.()
    end)
  end

  defp paid_finalize do
    fn ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => @order_id, "status" => "paid", "subtotal_amount" => @gross}
       }}
    end
  end

  defp declined_finalize do
    fn -> {:ok, %Req.Response{status: 402, body: %{"detail" => "no payment method"}}} end
  end
end

defmodule FluxVale.Billing.Operations.SweepAutoRechargeTest do
  @moduledoc """
  The reminder sweep (#829 L2): due + never reminded → mail AND marker
  (and a failed send rolls the marker back), the fixed 24h cadence,
  recovery clears the marker, an org nobody can reach still marks once,
  and per-org isolation.
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
    assert body =~ "$5"
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
    stub(Mailer, :deliver_auto_recharge_reminder, fn _to, _threshold_dollars, _url ->
      {:error, :postmark_down}
    end)

    assert {:error, "auto-recharge reminder sweep failed for 1 org(s)"} =
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

    stub(Mailer, :deliver_auto_recharge_reminder, fn to, _threshold_dollars, _url ->
      if to == distinctive do
        raise "org A's send is on fire"
      else
        {:ok, %{}}
      end
    end)

    assert {:error, "auto-recharge reminder sweep failed for 1 org(s)"} =
             Billing.sweep_auto_recharge()

    # Org B's reminder went out (the stub's delivered branch) and its
    # marker landed — the stub bypasses Swoosh, so the delivery is
    # asserted on the call log, not a mailbox message.
    deliveries = Mimic.calls(&Mailer.deliver_auto_recharge_reminder/3)
    delivered_to = Enum.map(deliveries, fn [to, _threshold, _url] -> to end)
    assert AccountsFixtures.primary_address!(owner_b) in delivered_to

    assert {:ok, fresh_b} = AutoRechargeSetting.get_by_organization(org_b.id, authorize?: false)
    assert fresh_b.last_reminded_at != nil

    # ...while org A's marker never landed.
    assert {:ok, fresh_a} = AutoRechargeSetting.get_by_organization(org_a.id, authorize?: false)
    assert fresh_a.last_reminded_at == nil
  end

  test "an org in :off mode never sweeps", %{org: org, owner: owner, setting: setting} do
    {:ok, _off} = AutoRechargeSetting.set(setting, %{mode: :off}, actor: owner)

    # The wallet is funded below the threshold — due, but not armed.
    assert {:ok, %{reminded: 0}} = Billing.sweep_auto_recharge()
    refute_received {:email, _email}

    assert {:ok, fresh} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert fresh.last_reminded_at == nil
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

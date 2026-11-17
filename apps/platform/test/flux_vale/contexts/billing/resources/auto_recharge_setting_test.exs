defmodule FluxVale.Billing.AutoRechargeSettingTest do
  @moduledoc """
  The AutoRechargeSetting resource contract (#829 L1): one row per org,
  launch defaults, owner-role writes, member reads, the system-only
  reminder marker, and the paper trail.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  setup do
    # grant_free_org! — {org, owner}: the fixture org's one member is
    # its owner, the actor the :set policy admits.
    {org, owner} = BillingFixtures.grant_free_org!()

    # authorize?: false — the create is system-only by policy; this is
    # the provisioning seam's posture (bootstrap, mirroring seeds).
    {:ok, setting} = AutoRechargeSetting.create(%{organization_id: org.id}, authorize?: false)

    %{org: org, owner: owner, setting: setting}
  end

  test "a fresh row ships the launch defaults (decision D)", %{setting: setting} do
    assert setting.mode == :off
    assert setting.threshold_cents == 500
    assert setting.amount_cents == 2_500
    assert is_nil(setting.last_reminded_at)

    # The staged charge lane's defaults (S2): the data ships, the gate
    # keeps the lane inert — no write can arm :auto while charge_mode
    # is false.
    assert setting.daily_charge_cap == 2
    assert setting.failure_strikes == 3
    assert setting.consecutive_failures == 0
    assert is_nil(setting.disabled_reason)
    assert is_nil(setting.no_method_notified_at)
    assert is_nil(setting.last_attempt_at)
    assert is_nil(setting.provider_customer_id)
    assert setting.payment_method_status == :none
    assert is_nil(setting.billing_country)
    assert is_nil(setting.billing_state)
    assert is_nil(setting.vat_number)
    assert setting.customer_type == :consumer
  end

  test "an org has exactly one setting (unique_org)", %{org: org, setting: setting} do
    assert {:error, %Ash.Error.Invalid{}} =
             AutoRechargeSetting.create(%{organization_id: org.id}, authorize?: false)

    assert {:ok, same} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert same.id == setting.id
  end

  test "the domain delegates wrap the code interface (the public seam)", %{
    org: org,
    setting: setting,
    owner: owner
  } do
    assert {:ok, read} = Billing.get_auto_recharge_setting(org.id, actor: owner)
    assert read.id == setting.id

    assert {:ok, set} =
             Billing.set_auto_recharge_setting(setting, %{mode: :reminder}, actor: owner)

    assert set.mode == :reminder
  end

  describe "read" do
    test "a member reads their org's setting", %{org: org} do
      member = member!(org)

      assert {:ok, %AutoRechargeSetting{}} =
               AutoRechargeSetting.get_by_organization(org.id, actor: member)
    end

    test "a stranger's read filters to nothing (the wrapped NotFound shape)", %{org: org} do
      stranger = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               AutoRechargeSetting.get_by_organization(org.id, actor: stranger)
    end

    test "a platform admin reads any setting (the #644 bypass)", %{org: org} do
      assert {:ok, %AutoRechargeSetting{}} =
               AutoRechargeSetting.get_by_organization(org.id, actor: admin())
    end
  end

  describe "set (the owner-role write)" do
    test "the org's owner sets mode, threshold, and amount", %{setting: setting, owner: owner} do
      floor = Billing.min_topup_cents()

      assert {:ok, set} =
               AutoRechargeSetting.set(
                 setting,
                 %{mode: :reminder, threshold_cents: 1_000, amount_cents: floor},
                 actor: owner
               )

      assert set.mode == :reminder
      assert set.threshold_cents == 1_000
      # The amount at exactly the floor is admitted — the gate is
      # >=, read from config at validation time.
      assert set.amount_cents == floor
    end

    test "a member (non-owner) cannot set — recurring spend consent is owner-only (decision C)",
         %{
           org: org,
           setting: setting
         } do
      member = member!(org)

      assert {:error, %Ash.Error.Forbidden{}} =
               AutoRechargeSetting.set(setting, %{mode: :reminder}, actor: member)
    end

    test "a stranger (no membership at all) cannot set", %{setting: setting} do
      stranger = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               AutoRechargeSetting.set(setting, %{mode: :reminder}, actor: stranger)
    end

    test "a platform admin bypasses (:set, #644)", %{setting: setting} do
      assert {:ok, set} = AutoRechargeSetting.set(setting, %{mode: :reminder}, actor: admin())
      assert set.mode == :reminder
    end
  end

  describe "attribute constraints" do
    test "a threshold below 100¢ is rejected (the attribute constraint)", %{
      setting: setting,
      owner: owner
    } do
      assert {:error, %Ash.Error.Invalid{}} =
               AutoRechargeSetting.set(setting, %{threshold_cents: 50}, actor: owner)
    end

    test "an amount below the runtime top-up floor is rejected (AmountMeetsTopupFloor)", %{
      setting: setting,
      owner: owner
    } do
      below_floor = Billing.min_topup_cents() - 100

      assert {:error, %Ash.Error.Invalid{}} =
               AutoRechargeSetting.set(setting, %{amount_cents: below_floor}, actor: owner)
    end

    test "a mode the enum does not carry is rejected", %{
      setting: setting,
      owner: owner
    } do
      assert {:error, %Ash.Error.Invalid{}} =
               AutoRechargeSetting.set(setting, %{mode: :bogus}, actor: owner)
    end
  end

  describe "record_reminder (the system marker)" do
    test "the sweep seam writes and clears the marker", %{setting: setting} do
      now = DateTime.utc_now(:microsecond)

      # authorize?: false — the marker is the L2 sweep's system write
      # (actor-forbidden by policy; this mirrors the production caller).
      assert {:ok, reminded} =
               setting
               |> Ash.Changeset.for_update(:record_reminder, %{last_reminded_at: now})
               |> Ash.update(authorize?: false)

      assert reminded.last_reminded_at == now

      # Clear from the REMINDED struct — the original still holds nil,
      # and Ash drops a nil-to-nil change (the clear must act on a set
      # marker to prove anything).
      assert {:ok, cleared} =
               reminded
               |> Ash.Changeset.for_update(:record_reminder, %{last_reminded_at: nil})
               |> Ash.update(authorize?: false)

      assert is_nil(cleared.last_reminded_at)

      # The persisted row, not just the returned struct.
      assert {:ok, reloaded} =
               AutoRechargeSetting.get_by_organization(setting.organization_id, authorize?: false)

      assert reloaded.last_reminded_at == nil
    end

    test "actor-forbidden for every actor the policies see; the admin blanket admits (#644)", %{
      org: org,
      setting: setting,
      owner: owner
    } do
      member = member!(org)

      for actor <- [member, owner] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 setting
                 |> Ash.Changeset.for_update(:record_reminder, %{
                   last_reminded_at: DateTime.utc_now()
                 })
                 |> Ash.update(actor: actor)
      end

      # ADR-0047's D4: the platform-admin bypass covers system-only
      # gates too — the write is policy-admitted for a non-PAT admin.
      assert {:ok, _updated} =
               setting
               |> Ash.Changeset.for_update(:record_reminder, %{
                 last_reminded_at: DateTime.utc_now()
               })
               |> Ash.update(actor: admin())
    end
  end

  describe "the charge gate (S2, staged — the launch posture)" do
    test "the gate reads false by default" do
      refute Billing.auto_recharge_charge_mode?()
    end

    test ":set with mode :auto is rejected with the gate message while the gate is off", %{
      setting: setting,
      owner: owner
    } do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AutoRechargeSetting.set(setting, %{mode: :auto}, actor: owner)

      assert Enum.any?(
               errors,
               &match?(
                 %Ash.Error.Changes.InvalidAttribute{
                   field: :mode,
                   message: "the auto-recharge charge lane is not enabled on this platform"
                 },
                 &1
               )
             )
    end

    test "the staged caps and buyer evidence are owner-settable (inert data, not gated)", %{
      setting: setting,
      owner: owner
    } do
      assert {:ok, set} =
               AutoRechargeSetting.set(
                 setting,
                 %{
                   daily_charge_cap: 4,
                   failure_strikes: 5,
                   billing_country: "DE",
                   billing_state: "BE",
                   vat_number: "DE123456789",
                   customer_type: :business
                 },
                 actor: owner
               )

      assert set.daily_charge_cap == 4
      assert set.failure_strikes == 5

      # The persisted row, not just the returned struct.
      assert {:ok, reloaded} =
               AutoRechargeSetting.get_by_organization(setting.organization_id,
                 authorize?: false
               )

      assert reloaded.billing_country == "DE"
      assert reloaded.billing_state == "BE"
      assert reloaded.vat_number == "DE123456789"
      assert reloaded.customer_type == :business
    end

    test "the charge-lane system writes are actor-forbidden; the admin blanket admits (#644)", %{
      org: org,
      setting: setting,
      owner: owner
    } do
      member = member!(org)

      attempts = [
        {:record_attempt_outcome,
         %{consecutive_failures: 1, last_attempt_at: DateTime.utc_now()}},
        {:disable_with_reason, %{disabled_reason: :manual}},
        {:set_method_status, %{payment_method_status: :attached, provider_customer_id: "cust_1"}}
      ]

      for actor <- [member, owner], {action, params} <- attempts do
        assert {:error, %Ash.Error.Forbidden{}} =
                 setting
                 |> Ash.Changeset.for_update(action, params)
                 |> Ash.update(actor: actor)
      end

      for {action, params} <- attempts do
        assert {:ok, _updated} =
                 setting
                 |> Ash.Changeset.for_update(action, params)
                 |> Ash.update(actor: admin())
      end
    end
  end

  describe "arming :auto (the gate on)" do
    setup do
      # Global app env — the stub_build_sha posture: capture, flip,
      # restore on exit. Within a module tests run serially, and no
      # other suite reads this key (nothing else consumes the gate yet).
      original = Application.get_env(:flux_vale, :auto_recharge)
      Application.put_env(:flux_vale, :auto_recharge, charge_mode: true)

      on_exit(fn ->
        if original do
          Application.put_env(:flux_vale, :auto_recharge, original)
        else
          Application.delete_env(:flux_vale, :auto_recharge)
        end
      end)

      :ok
    end

    test "the gate reads true when flipped" do
      assert Billing.auto_recharge_charge_mode?()
    end

    test ":set with mode :auto and no saved method is rejected (arming consent requires a method, decision C)",
         %{setting: setting, owner: owner} do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AutoRechargeSetting.set(setting, %{mode: :auto}, actor: owner)

      assert Enum.any?(
               errors,
               &match?(
                 %Ash.Error.Changes.InvalidAttribute{
                   field: :mode,
                   message: "arming :auto requires a saved payment method"
                 },
                 &1
               )
             )
    end

    test ":set with mode :auto is admitted once a method is attached", %{
      setting: setting,
      owner: owner
    } do
      # authorize?: false — the method status is the save-method flow's
      # system write; this mirrors the production caller.
      assert {:ok, attached} =
               setting
               |> Ash.Changeset.for_update(:set_method_status, %{
                 payment_method_status: :attached,
                 provider_customer_id: "polar-cust-123"
               })
               |> Ash.update(authorize?: false)

      assert {:ok, armed} = AutoRechargeSetting.set(attached, %{mode: :auto}, actor: owner)
      assert armed.mode == :auto
    end

    test "disable_with_reason records the reason, disarms to :off, and clears the no-method marker",
         %{setting: setting, owner: owner} do
      # authorize?: false — the method status is the save-method flow's
      # system write; then the owner arms through :set.
      assert {:ok, attached} =
               setting
               |> Ash.Changeset.for_update(:set_method_status, %{payment_method_status: :attached})
               |> Ash.update(authorize?: false)

      assert {:ok, armed} = AutoRechargeSetting.set(attached, %{mode: :auto}, actor: owner)

      # D3's notice marker is written only by S4's sweep — no S2 action
      # accepts it (the sanctioned states-actions-can't-produce case,
      # the tax_summary_test posture): forced onto a system changeset.
      assert {:ok, armed} =
               armed
               |> Ash.Changeset.for_update(:record_reminder, %{})
               |> Ash.Changeset.force_change_attribute(
                 :no_method_notified_at,
                 DateTime.utc_now(:microsecond)
               )
               |> Ash.update(authorize?: false)

      # authorize?: false — the disable is the strikes/no-method system
      # write (actor-forbidden by policy; mirrors the production caller).
      assert {:ok, disabled} =
               armed
               |> Ash.Changeset.for_update(:disable_with_reason, %{disabled_reason: :declines})
               |> Ash.update(authorize?: false)

      assert disabled.mode == :off
      assert disabled.disabled_reason == :declines
      assert is_nil(disabled.no_method_notified_at)

      # The persisted row, not just the returned struct.
      assert {:ok, reloaded} =
               AutoRechargeSetting.get_by_organization(setting.organization_id, authorize?: false)

      assert reloaded.mode == :off
      assert reloaded.disabled_reason == :declines
    end
  end

  describe "record_attempt_outcome (the sweep seam)" do
    test "the sweep writes and resets the strike counter and stamps the attempt", %{
      setting: setting
    } do
      now = DateTime.utc_now(:microsecond)

      # authorize?: false — the outcome is the S4 sweep's system write
      # (actor-forbidden by policy; this mirrors the production caller).
      assert {:ok, counted} =
               setting
               |> Ash.Changeset.for_update(:record_attempt_outcome, %{
                 consecutive_failures: 2,
                 last_attempt_at: now
               })
               |> Ash.update(authorize?: false)

      assert counted.consecutive_failures == 2
      assert counted.last_attempt_at == now

      # A success resets the counter and nil clears the marker (the
      # record_reminder semantics — act on a set value to prove it).
      assert {:ok, reset} =
               counted
               |> Ash.Changeset.for_update(:record_attempt_outcome, %{
                 consecutive_failures: 0,
                 last_attempt_at: nil
               })
               |> Ash.update(authorize?: false)

      assert reset.consecutive_failures == 0
      assert is_nil(reset.last_attempt_at)

      # The persisted row, not just the returned struct.
      assert {:ok, reloaded} =
               AutoRechargeSetting.get_by_organization(setting.organization_id, authorize?: false)

      assert reloaded.last_attempt_at == nil
    end
  end

  describe "charge attribute constraints" do
    test "daily_charge_cap outside 1–6 is rejected; the bounds are admitted", %{
      setting: setting,
      owner: owner
    } do
      for cap <- [0, 7] do
        assert {:error, %Ash.Error.Invalid{}} =
                 AutoRechargeSetting.set(setting, %{daily_charge_cap: cap}, actor: owner)
      end

      for cap <- [1, 6] do
        assert {:ok, _set} =
                 AutoRechargeSetting.set(setting, %{daily_charge_cap: cap}, actor: owner)
      end
    end

    test "failure_strikes outside 2–5 is rejected; the bounds are admitted", %{
      setting: setting,
      owner: owner
    } do
      for strikes <- [1, 6] do
        assert {:error, %Ash.Error.Invalid{}} =
                 AutoRechargeSetting.set(setting, %{failure_strikes: strikes}, actor: owner)
      end

      for strikes <- [2, 5] do
        assert {:ok, _set} =
                 AutoRechargeSetting.set(setting, %{failure_strikes: strikes}, actor: owner)
      end
    end

    test "values the system-write enums do not carry are rejected", %{setting: setting} do
      assert {:error, %Ash.Error.Invalid{}} =
               setting
               |> Ash.Changeset.for_update(:disable_with_reason, %{disabled_reason: :bogus})
               |> Ash.update(authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               setting
               |> Ash.Changeset.for_update(:set_method_status, %{payment_method_status: :bogus})
               |> Ash.update(authorize?: false)
    end
  end

  describe "paper trail" do
    test "a :set write produces an attributed version row", %{setting: setting, owner: owner} do
      assert {:ok, _set} =
               AutoRechargeSetting.set(setting, %{mode: :reminder, amount_cents: 4_000},
                 actor: owner
               )

      # Version-row reads that assert STORAGE run authorize?: false (the
      # paper_trail_test posture).
      versions =
        AutoRechargeSetting.Version
        |> Ash.Query.filter(version_source_id == ^setting.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      [create_version, set_version] = versions

      # The row is born of the provisioning seam — its create-version
      # carries the honest nil actor.
      assert create_version.version_action_type == :create
      assert is_nil(create_version.user_id)

      assert set_version.version_action_name == :set
      assert set_version.version_action_type == :update
      # Enums dump to their string form in the trail (the wallet's
      # "reason" => "adjustment" shape).
      assert set_version.changes["mode"] == "reminder"
      assert set_version.changes["amount_cents"] == 4_000
      assert set_version.version_action_inputs["mode"] == "reminder"
      assert set_version.user_id == owner.id
      assert set_version.actor_label == owner.username
    end

    test "buyer evidence redacts in BOTH changes and version_action_inputs (ADR-0048)", %{
      setting: setting,
      owner: owner
    } do
      # The staged evidence attributes carry sensitive?(true) (the
      # Topup posture), so the blanket sensitive_attributes :redact
      # keeps their values out of the trail — every flagged key reads
      # REDACTED, the non-sensitive dials stay plaintext.
      assert {:ok, _set} =
               AutoRechargeSetting.set(
                 setting,
                 %{
                   daily_charge_cap: 3,
                   billing_country: "DE",
                   billing_state: "BE",
                   vat_number: "DE123456789",
                   customer_type: :business
                 },
                 actor: owner
               )

      # Version-row reads that assert STORAGE run authorize?: false (the
      # paper_trail_test posture).
      versions =
        AutoRechargeSetting.Version
        |> Ash.Query.filter(version_source_id == ^setting.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      [_create_version, set_version] = versions

      redacted = ~w(billing_country billing_state vat_number customer_type)

      for key <- redacted do
        assert set_version.changes[key] == "REDACTED",
               "#{key} leaked into changes — the flag is not covering it"

        assert set_version.version_action_inputs[key] == "REDACTED",
               "#{key} leaked into version_action_inputs — the flag is not covering it"
      end

      assert set_version.changes["daily_charge_cap"] == 3
    end
  end

  defp member!(org) do
    user = AccountsFixtures.user!()

    # authorize?: false — memberships are system-created (the bootstrap
    # posture, mirroring seeds).
    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :member},
      authorize?: false
    )

    user
  end

  # Bootstrap posture (mirrors the wallet suite): the precondition runs
  # authorize?: false; the policy itself is under test above.
  defp admin, do: AccountsFixtures.platform_admin!()
end

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

    test "a mode the enum does not carry is rejected (:auto arrives with S2)", %{
      setting: setting,
      owner: owner
    } do
      assert {:error, %Ash.Error.Invalid{}} =
               AutoRechargeSetting.set(setting, %{mode: :auto}, actor: owner)
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

      assert {:ok, cleared} =
               setting
               |> Ash.Changeset.for_update(:record_reminder, %{last_reminded_at: nil})
               |> Ash.update(authorize?: false)

      assert is_nil(cleared.last_reminded_at)
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

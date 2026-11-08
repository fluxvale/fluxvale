defmodule FluxVale.Infrastructure.Operations.SetPocketIdKeyTest do
  @moduledoc """
  The custody intake seam (#597 §4.3): owner-only, verified live
  before anything is stored, Secret first then row, the key never
  comes back — the op's return carries the custody row, the row holds
  only the Secret's NAME. Every paste is audited (D1 amendment): a
  :used event for the verification, :stored/:replaced for the change.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdCustodyEvent
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @key "test-key-not-a-real-credential"

  setup do
    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    # Instance create rides the funded-wallet gate (#124).
    BillingFixtures.funded_wallet!(org: org)

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    stub(ApiClient, :verify_admin_key, fn _url, _key -> :ok end)
    stub(ApiClient, :list_api_keys, fn _url, _key -> {:ok, []} end)
    stub(Secret, :create, fn _kc, _ns, _name, _data -> {:ok, %{}} end)

    version = InstanceFixtures.app_version!()
    instance = InstanceFixtures.instance!(version, owner)

    {:ok, org: org, owner: owner, instance: instance}
  end

  defp events(instance) do
    {:ok, rows} = PocketIdCustodyEvent.for_instance(instance.id, authorize?: false)
    rows
  end

  test "verifies live, writes the Secret, records only its NAME on the row", %{
    owner: owner,
    instance: instance
  } do
    verified_url = "https://#{instance.slug}.fluxvale.lvh.me"

    expect(ApiClient, :verify_admin_key, fn url, key ->
      assert url == verified_url
      assert key == @key
      :ok
    end)

    expect(Secret, :create, fn _kc, namespace, name, data ->
      assert namespace == InstanceK8s.gateway_access_namespace()
      assert name == "fluxvale-pocketid-custody-#{instance.id}"
      assert data == %{"POCKETID_API_KEY" => @key}
      {:ok, %{}}
    end)

    assert {:ok, custody} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)

    row = PocketIdCustody.get_by_instance!(instance.id, authorize?: false)
    assert row.id == custody.id
    assert row.api_key_secret_ref == "fluxvale-pocketid-custody-#{instance.id}"
    assert %DateTime{} = row.verified_at

    # The key appears NOWHERE in the result or the row (§4.3).
    refute "#{inspect(custody)}" =~ @key
    refute "#{inspect(row)}" =~ @key

    # D1: the paste-time verification is a use; the store is a custody
    # change — two honest events, actor = the owner. Newest first (the
    # audit read's order): :stored landed after the :used it rode on.
    assert [
             %PocketIdCustodyEvent{kind: :stored, purpose: nil},
             %PocketIdCustodyEvent{kind: :used, purpose: "verification"}
           ] = events(instance)
  end

  test "a re-paste replaces in place: new ref stamps, a :replaced event", %{
    owner: owner,
    instance: instance
  } do
    assert {:ok, first} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)
    assert {:ok, second} = Infrastructure.set_pocket_id_key(instance, "a-fresh-key", actor: owner)

    # One row, updated — the identity's one-custody-per-instance.
    assert second.id == first.id
    assert DateTime.compare(second.verified_at, first.verified_at) in [:gt, :eq]

    rows = events(instance)
    kinds = Enum.map(rows, & &1.kind)
    assert kinds == [:replaced, :used, :stored, :used]
  end

  test "a rejected key (401) stores nothing and audits nothing", %{
    owner: owner,
    instance: instance
  } do
    stub(ApiClient, :verify_admin_key, fn _url, _key -> {:error, :unauthorized} end)

    stub(Secret, :create, fn _kc, _ns, _n, _d -> flunk("no Secret for a rejected key") end)

    assert {:error, :unauthorized} =
             Infrastructure.set_pocket_id_key(instance, @key, actor: owner)

    assert {:error, _none} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)
    assert [] = events(instance)
  end

  test "a key without admin permission (403) is its own honest verdict", %{
    owner: owner,
    instance: instance
  } do
    stub(ApiClient, :verify_admin_key, fn _url, _key -> {:error, :forbidden} end)

    assert {:error, :forbidden} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)
    assert [] = events(instance)
  end

  test "an unreachable PocketID fails honestly, storing nothing", %{
    owner: owner,
    instance: instance
  } do
    stub(ApiClient, :verify_admin_key, fn _url, _key -> {:error, :unreachable} end)

    assert {:error, :unreachable} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)
    assert [] = events(instance)
  end

  test "a private PocketID is refused before any HTTP call", %{
    owner: owner,
    instance: instance
  } do
    private = InstanceFixtures.pin!(instance, exposure: :private)

    stub(ApiClient, :verify_admin_key, fn _url, _key ->
      flunk("no call for a private PocketID")
    end)

    assert {:error, :not_public} =
             Infrastructure.set_pocket_id_key(private, @key, actor: owner)
  end

  test "a member of the org (not an owner) is refused before any call", %{
    org: org,
    instance: instance
  } do
    member = AccountsFixtures.user!()

    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    stub(ApiClient, :verify_admin_key, fn _url, _key -> flunk("the crown is the owner's") end)

    assert {:error, :not_org_owner} =
             Infrastructure.set_pocket_id_key(instance, @key, actor: member)

    assert {:error, _none} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)
  end

  test "a non-member is Forbidden on the authorized read", %{
    instance: instance
  } do
    {_other_org, stranger} = BillingFixtures.grant_free_org!()

    stub(ApiClient, :verify_admin_key, fn _url, _key -> flunk("no call for a stranger") end)

    assert {:error, _forbidden} =
             Infrastructure.set_pocket_id_key(instance, @key, actor: stranger)
  end

  test "a nil actor is refused as not-an-owner even authorize?-free", %{
    instance: instance
  } do
    assert {:error, :not_org_owner} =
             Infrastructure.set_pocket_id_key(instance, @key, authorize?: false)
  end

  test "a Secret write failure surfaces; no row lands (the retry converges)", %{
    owner: owner,
    instance: instance
  } do
    stub(Secret, :create, fn _kc, _ns, _n, _d -> {:error, :cluster_oops} end)

    assert {:error, :cluster_oops} =
             Infrastructure.set_pocket_id_key(instance, @key, actor: owner)

    assert {:error, _none} = PocketIdCustody.get_by_instance(instance.id, authorize?: false)

    # The verification DID happen (it is a use, audited); the custody
    # change did not.
    assert [%PocketIdCustodyEvent{kind: :used}] = events(instance)
  end

  describe "the expiry nicety — best-effort, never a gate" do
    test "an unambiguous correlation stores the key family's expiresAt", %{
      owner: owner,
      instance: instance
    } do
      now = DateTime.utc_now()

      stub(ApiClient, :list_api_keys, fn _url, _key ->
        {:ok,
         [
           # Idle sibling key — outside the window.
           %{"id" => "old", "lastUsedAt" => iso(now, -86_400), "expiresAt" => nil},
           # The just-used key.
           %{
             "id" => "used",
             "lastUsedAt" => iso(now, -2),
             "expiresAt" => iso(now, 2_592_000)
           }
         ]}
      end)

      assert {:ok, custody} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)
      assert %DateTime{} = custody.expires_at
      assert DateTime.diff(custody.expires_at, now, :second) == 2_592_000
    end

    test "several in-window keys are ambiguous — nil, not a guess", %{
      owner: owner,
      instance: instance
    } do
      now = DateTime.utc_now()

      stub(ApiClient, :list_api_keys, fn _url, _key ->
        {:ok,
         [
           %{"id" => "a", "lastUsedAt" => iso(now, -3), "expiresAt" => iso(now, 1)},
           %{"id" => "b", "lastUsedAt" => iso(now, -4), "expiresAt" => iso(now, 2)}
         ]}
      end)

      assert {:ok, custody} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)
      assert custody.expires_at == nil
    end

    test "a correlated key with no expiresAt stores nil — Pocket ID's own no-expiry keys", %{
      owner: owner,
      instance: instance
    } do
      now = DateTime.utc_now()

      stub(ApiClient, :list_api_keys, fn _url, _key ->
        {:ok, [%{"id" => "used", "lastUsedAt" => iso(now, -2)}]}
      end)

      assert {:ok, custody} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)
      assert custody.expires_at == nil
    end

    test "a listing failure degrades to nil — the store still succeeds", %{
      owner: owner,
      instance: instance
    } do
      stub(ApiClient, :list_api_keys, fn _url, _key -> {:error, :unreachable} end)

      assert {:ok, custody} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)
      assert custody.expires_at == nil
    end

    # Corrupt wire data (an unparseable expiresAt, a never-used sibling,
    # non-string fields) is unusable for correlation, never a crash —
    # the nicety degrades and the store stands.
    test "garbage timestamps degrade to nil — never a crash", %{
      owner: owner,
      instance: instance
    } do
      stub(ApiClient, :list_api_keys, fn _url, _key ->
        {:ok,
         [
           %{
             "id" => "only",
             "lastUsedAt" => DateTime.to_iso8601(DateTime.utc_now()),
             "expiresAt" => "not-a-date"
           },
           %{"id" => "never-used", "lastUsedAt" => nil},
           %{"id" => "junk", "lastUsedAt" => 44}
         ]}
      end)

      assert {:ok, custody} = Infrastructure.set_pocket_id_key(instance, @key, actor: owner)
      assert custody.expires_at == nil
    end
  end

  defp iso(now, shift_seconds) do
    now
    |> DateTime.add(shift_seconds, :second)
    |> DateTime.to_iso8601()
  end
end

defmodule FluxVale.OAuth.Operations.PruneTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Janitor.PruneDeviceGrants
  alias FluxVale.Janitor.PruneOAuthAuditEvents
  alias FluxVale.Janitor.PruneOAuthCodes
  alias FluxVale.OAuth
  alias FluxVale.OAuth.AuditEvent
  alias FluxVale.OAuth.AuthorizationCode
  alias FluxVale.OAuth.DeviceGrant

  setup do
    %{client: client!(), user: user!()}
  end

  test "prune_codes deletes only codes past the retention horizon", %{
    client: client,
    user: user
  } do
    old = seed_code(client, user, DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second))
    fresh = issue_code!(client, user).record

    assert {:ok, 1} = OAuth.prune_codes(authorize?: false)

    assert {:error, _not_found} =
             AuthorizationCode.get_by_code_hash(old.code_hash, authorize?: false)

    assert {:ok, %AuthorizationCode{}} =
             AuthorizationCode.get_by_code_hash(fresh.code_hash, authorize?: false)
  end

  test "prune_audit_events deletes only rows past the retention horizon" do
    old = seed_audit(DateTime.add(DateTime.utc_now(), -91 * 24 * 60 * 60, :second))

    :ok = OAuth.record_audit_event(%{kind: :client_registered, metadata: %{}})

    assert {:ok, 1} = OAuth.prune_audit_events(authorize?: false)

    ids = audit_ids()
    refute old.id in ids
    # The setup client and the action-written row are inside the
    # horizon and survive.
    assert length(ids) >= 2
  end

  test "the janitor jobs delegate to the prune ops", %{client: client, user: user} do
    seed_code(client, user, DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second))
    seed_audit(DateTime.add(DateTime.utc_now(), -91 * 24 * 60 * 60, :second))
    seed_grant(client, DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second))

    assert {:ok, 1} = PruneOAuthCodes.perform(%Oban.Job{})
    assert {:ok, 1} = PruneOAuthAuditEvents.perform(%Oban.Job{})
    assert {:ok, 1} = PruneDeviceGrants.perform(%Oban.Job{})
  end

  test "prune_device_grants deletes only grants past the retention horizon", %{client: client} do
    old = seed_grant(client, DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second))
    fresh = device_grant!(client).grant

    assert {:ok, 1} = OAuth.prune_device_grants(authorize?: false)

    assert {:error, _not_found} =
             DeviceGrant.get_by_device_code_hash(old.device_code_hash, authorize?: false)

    assert {:ok, %DeviceGrant{}} =
             DeviceGrant.get_by_device_code_hash(fresh.device_code_hash, authorize?: false)
  end

  test "a terminal grant survives its first day, then the second arm sweeps it", %{client: client} do
    # Terminal (:consumed) rows are swept by the status+updated_at arm
    # once past the horizon — the retention claim's other half.
    approver = user!()
    minted = device_grant!(client)
    {:ok, approved} = OAuth.approve_device_grant(minted.grant, actor: approver)
    consumed = DeviceGrant.consume!(approved, authorize?: false)

    # An hour back: inside the horizon — the row survives so a racing
    # poll still answers expired_token, not "unknown".
    hour_old = DateTime.add(DateTime.utc_now(), -1, :hour)
    backdated = Ash.Seed.update!(consumed, %{updated_at: hour_old})
    assert {:ok, 0} = OAuth.prune_device_grants(authorize?: false)

    assert {:ok, %DeviceGrant{}} =
             DeviceGrant.get_by_device_code_hash(backdated.device_code_hash, authorize?: false)

    # Two days back: past the horizon — the second arm sweeps it.
    two_days_old = DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second)
    swept = Ash.Seed.update!(backdated, %{updated_at: two_days_old})
    assert {:ok, 1} = OAuth.prune_device_grants(authorize?: false)

    assert {:error, _not_found} =
             DeviceGrant.get_by_device_code_hash(swept.device_code_hash, authorize?: false)
  end

  # Backdated expiry is an action-impossible state: the mint action
  # always stamps a 10-minute window, so the sweep's horizon needs a
  # seed.
  defp seed_grant(client, expires_at) do
    random_bytes = :crypto.strong_rand_bytes(32)
    random_suffix = Base.url_encode64(random_bytes, padding: false)

    Ash.Seed.seed!(DeviceGrant, %{
      device_code_hash: PersonalAccessToken.token_hash(random_suffix),
      user_code: user_code(),
      scopes: [],
      resource: "https://mcp.fluxvale.com/mcp",
      code_challenge: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      status: :pending,
      expires_at: expires_at,
      client_id: client.id
    })
  end

  defp user_code do
    symbols =
      Enum.map(1..8, fn _i -> Enum.random(~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789") end)

    {left, right} = Enum.split(symbols, 4)
    IO.iodata_to_binary([left, ?-, right])
  end

  # Backdated expiry is an action-impossible state: the issue action
  # always mints a 60-second code, so the sweep's horizon needs a seed.
  defp seed_code(client, user, expires_at) do
    Ash.Seed.seed!(AuthorizationCode, %{
      code_hash: Base.encode16(:crypto.strong_rand_bytes(32)),
      redirect_uri: "http://127.0.0.1:53682/callback",
      scopes: [],
      resource: "https://mcp.fluxvale.com/mcp",
      code_challenge: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      code_challenge_method: "S256",
      expires_at: expires_at,
      client_id: client.id,
      user_id: user.id
    })
  end

  defp audit_ids do
    cutoff = DateTime.add(DateTime.utc_now(), 60, :second)

    AuditEvent
    |> Ash.Query.for_read(:stale, %{cutoff: cutoff})
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  # Backdated created_at is action-impossible: record/1 stamps now.
  defp seed_audit(created_at) do
    Ash.Seed.seed!(AuditEvent, %{
      kind: :client_registered,
      created_at: created_at,
      metadata: %{}
    })
  end
end

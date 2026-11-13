defmodule FluxVale.OAuth.Operations.PruneTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.Janitor.PruneOAuthAuditEvents
  alias FluxVale.Janitor.PruneOAuthCodes
  alias FluxVale.OAuth
  alias FluxVale.OAuth.AuditEvent
  alias FluxVale.OAuth.AuthorizationCode

  setup do
    %{client: client!(), user: user!()}
  end

  test "prune_codes deletes only codes past the retention horizon", %{
    client: client,
    user: user
  } do
    old = seed_code(client, user, DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second))
    fresh = seed_code(client, user, DateTime.add(DateTime.utc_now(), 30, :second))

    assert {:ok, 1} = OAuth.prune_codes(authorize?: false)

    assert {:error, _not_found} =
             AuthorizationCode.get_by_code_hash(old.code_hash, authorize?: false)

    assert {:ok, %AuthorizationCode{}} =
             AuthorizationCode.get_by_code_hash(fresh.code_hash, authorize?: false)
  end

  test "prune_audit_events deletes only rows past the retention horizon" do
    old = seed_audit(DateTime.add(DateTime.utc_now(), -91 * 24 * 60 * 60, :second))
    fresh = seed_audit(DateTime.utc_now())

    assert {:ok, 1} = OAuth.prune_audit_events(authorize?: false)

    ids = audit_ids()
    refute old.id in ids
    assert fresh.id in ids
  end

  test "the janitor jobs delegate to the prune ops", %{client: client, user: user} do
    seed_code(client, user, DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second))
    seed_audit(DateTime.add(DateTime.utc_now(), -91 * 24 * 60 * 60, :second))

    assert {:ok, 1} = PruneOAuthCodes.perform(%Oban.Job{})
    assert {:ok, 1} = PruneOAuthAuditEvents.perform(%Oban.Job{})
  end

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

  defp seed_audit(created_at) do
    Ash.Seed.seed!(AuditEvent, %{
      kind: :client_registered,
      created_at: created_at,
      metadata: %{}
    })
  end
end

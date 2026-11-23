defmodule FluxVale.OAuth.Operations.DeviceGrantDecisionTest do
  @moduledoc false

  # #886: the hosted page's Allow/Deny — the actor bind, the guarded
  # transition (a moved row answers :stale), and the audit rows.

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.OAuthFixtures

  alias FluxVale.OAuth
  alias FluxVale.OAuth.AuditEvent
  alias FluxVale.OAuth.DeviceGrant

  require Ash.Query

  setup do
    %{client: client!(), user: user!(), other: user!()}
  end

  defp last_event(kind, client) do
    AuditEvent
    |> Ash.Query.for_read(:stale, %{cutoff: DateTime.add(DateTime.utc_now(), 60, :second)})
    |> Ash.Query.filter(kind == ^kind and oauth_client_id == ^client.id)
    |> Ash.read!(authorize?: false)
    |> List.last()
  end

  test "approve binds the approving user and records the decision", %{
    client: client,
    user: user
  } do
    minted = device_grant!(client)

    assert {:ok, approved} = OAuth.approve_device_grant(minted.grant, actor: user)
    assert approved.status == :approved
    assert approved.user_id == user.id

    event = last_event(:device_grant_approved, client)
    assert event.actor_id == user.id
    assert event.metadata["scopes"] == ["instances:read"]
  end

  test "deny is terminal and records the deciding actor", %{client: client, user: user} do
    minted = device_grant!(client)

    assert {:ok, denied} = OAuth.deny_device_grant(minted.grant, actor: user)
    assert denied.status == :denied
    # Deny never binds the row — the poll answers access_denied for
    # whoever asks, and no user is half-attached to a refusal.
    assert denied.user_id == nil

    event = last_event(:device_grant_denied, client)
    assert event.actor_id == user.id
  end

  test "approve without an actor is refused before any write", %{client: client} do
    minted = device_grant!(client)

    assert {:error, :actor_required} = OAuth.approve_device_grant(minted.grant)

    # The row is untouched — a later actor-ful approve still wins.
    assert {:ok, approved} = OAuth.approve_device_grant(minted.grant, actor: user!())
    assert approved.status == :approved
    assert approved.user_id != nil
  end

  test "deny without an actor is refused before any write", %{client: client} do
    minted = device_grant!(client)

    assert {:error, :actor_required} = OAuth.deny_device_grant(minted.grant)

    # The row is untouched — a later actor-ful deny still wins.
    assert {:ok, denied} = OAuth.deny_device_grant(minted.grant, actor: user!())
    assert denied.status == :denied
  end

  test "guarded consume and touch_poll transitions refuse wrong statuses", %{
    client: client,
    user: user
  } do
    pending_minted = device_grant!(client)

    assert {:error, %Ash.Error.Invalid{errors: consume_pending_errors}} =
             DeviceGrant.consume(pending_minted.grant, authorize?: false)

    assert Enum.any?(consume_pending_errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    assert {:ok, approved} = OAuth.approve_device_grant(pending_minted.grant, actor: user)

    assert {:error, %Ash.Error.Invalid{errors: touch_approved_errors}} =
             DeviceGrant.touch_poll(approved, authorize?: false)

    assert Enum.any?(touch_approved_errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    assert {:ok, consumed} = DeviceGrant.consume(approved, authorize?: false)

    assert {:error, %Ash.Error.Invalid{errors: reconsume_errors}} =
             DeviceGrant.consume(consumed, authorize?: false)

    assert Enum.any?(reconsume_errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  test "a row that moved between read and write answers :stale", %{
    client: client,
    user: user,
    other: other
  } do
    minted = device_grant!(client)

    assert {:ok, _denied} = OAuth.deny_device_grant(minted.grant, actor: other)
    assert {:error, :stale} = OAuth.approve_device_grant(minted.grant, actor: user)

    # The other direction: approve wins, the late deny stales.
    minted_again = device_grant!(client, %{"scope" => "wallet:read"})

    assert {:ok, _approved} = OAuth.approve_device_grant(minted_again.grant, actor: user)
    assert {:error, :stale} = OAuth.deny_device_grant(minted_again.grant, actor: other)
  end

  test "expired grants return :expired without mutating status or recording audit events", %{
    client: client,
    user: user
  } do
    minted_approve = device_grant!(client)
    past_approve = DateTime.add(minted_approve.grant.expires_at, 1, :second)

    assert {:error, :expired} =
             OAuth.approve_device_grant(minted_approve.grant, actor: user, now: past_approve)

    reloaded_approve =
      DeviceGrant.get_by_user_code!(minted_approve.grant.user_code, authorize?: false)

    assert reloaded_approve.status == :pending
    assert reloaded_approve.user_id == nil
    assert last_event(:device_grant_approved, client) == nil

    minted_deny = device_grant!(client)
    past_deny = DateTime.add(minted_deny.grant.expires_at, 1, :second)

    assert {:error, :expired} =
             OAuth.deny_device_grant(minted_deny.grant, actor: user, now: past_deny)

    reloaded_deny =
      DeviceGrant.get_by_user_code!(minted_deny.grant.user_code, authorize?: false)

    assert reloaded_deny.status == :pending
    assert reloaded_deny.user_id == nil
    assert last_event(:device_grant_denied, client) == nil
  end
end

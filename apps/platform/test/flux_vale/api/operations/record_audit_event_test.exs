defmodule FluxVale.Api.Operations.RecordAuditEventTest do
  @moduledoc false

  # #360 slice 5: the guarded append — the one write seam behind the
  # boundary plug and the mint/revoke operations.

  use FluxVale.DataCase, async: true

  import ExUnit.CaptureLog

  alias FluxVale.Api
  alias FluxVale.Api.AuditEvent
  alias FluxVale.Identity
  alias FluxVale.Identity.User

  setup do
    user = User.create!("audit-op@fluxvale.com", %{}, authorize?: false)

    {:ok, %{pat: pat}} =
      Identity.mint_pat(nil, %{user_id: user.id, name: "audit op", scopes: []}, authorize?: false)

    %{user: user, pat: pat}
  end

  describe "call/1" do
    test "appends a row with every column", %{pat: pat} do
      assert :ok =
               Api.record_audit_event(%{
                 kind: :request,
                 personal_access_token_id: pat.id,
                 method: "GET",
                 path: "/api/v1/me",
                 status_code: 200
               })

      # The setup mint left its own row — the request row is the new one.
      assert [%{kind: :mint}, %{kind: :request} = row] = audit_rows(pat.id)

      assert row.personal_access_token_id == pat.id
      assert row.method == "GET"
      assert row.path == "/api/v1/me"
      assert row.status_code == 200
      assert row.actor_id == nil
    end

    test "a failed write is logged and swallowed — the caller's outcome stands", %{pat: pat} do
      # An off-enum kind is refused by the type constraint before the
      # DB: the deterministic seam for the guard (the DB-outage arm is
      # the touch_last_used exclusion, not exercisable in-process).
      {result, log} =
        with_log(fn ->
          Api.record_audit_event(%{kind: :explode, personal_access_token_id: pat.id})
        end)

      assert :ok = result
      assert log =~ "audit write failed"
      assert log =~ "kind=explode"

      # Nothing appended — the setup's mint row is the whole trail.
      assert [%{kind: :mint}] = audit_rows(pat.id)
    end
  end

  defp audit_rows(token_id) do
    AuditEvent
    |> Ash.Query.for_read(:by_token, %{token_id: token_id})
    |> Ash.Query.sort([:created_at, :id])
    |> Ash.read!(authorize?: false)
  end
end

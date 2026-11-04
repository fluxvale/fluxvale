defmodule FluxValeWeb.Mcp.ConfirmTest do
  @moduledoc """
  The two destructive tools' confirmation contract (#361 slice 2,
  ADR-0019's confirmation UX): the first call ends as an
  `input_required` result carrying the confirm question and an
  encrypted `requestState` — no server state, nothing mutated. The
  resumed call runs the action on "yes"; any other answer ("no",
  decline) cancels without touching a row.

  Both arms prove the no-mutation side, the wire shape, and the full
  round trip — the requestState blob is encoded and decoded for real
  (the router's request_state keys are live), on the transport and
  through the in-process harness.
  """

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.Mcp

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.RestoreJob
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxValeWeb.MCP.Router

  require Ash.Query

  @elicit_caps %{"elicitation" => %{}}

  setup do
    Phantom.Test.start(router: Router)
    :ok
  end

  # --- restore_backup -------------------------------------------------

  describe "restore_backup over the transport" do
    test "the first call returns input_required with the confirm question — nothing mutated",
         %{conn: conn} do
      {_user, instance, run, pat} = restorable!()

      conn =
        call_tool(conn, pat, "restore_backup", %{"id" => instance.id, "backup_run_id" => run.id},
          capabilities: @elicit_caps
        )

      assert conn.status == 200
      result = result(conn)
      assert result["resultType"] == "input_required"
      assert is_binary(result["requestState"])

      assert %{"elicitation" => elicit} = result["inputRequests"]
      assert elicit["method"] == "elicitation/create"
      message = elicit["params"]["message"]
      assert message =~ "OVERWRITTEN"
      assert message =~ instance.name
      assert message =~ run.id

      # The question's one schema: confirm, yes/no, required.
      schema = elicit["params"]["requestedSchema"]
      assert schema["required"] == ["confirm"]
      assert schema["properties"]["confirm"]["enum"] == ["yes", "no"]

      # No mutation: the instance is still running, the run still
      # stands, and no restore-kind row exists.
      assert_instance_status!(instance, :running)
      assert run_still_succeeded!(run.id)
      assert restore_runs!(instance.id) == []
    end

    test "answering no over the wire cancels — still nothing mutated", %{conn: conn} do
      {_user, instance, run, pat} = restorable!()

      asked =
        call_tool(conn, pat, "restore_backup", %{"id" => instance.id, "backup_run_id" => run.id},
          capabilities: @elicit_caps
        )

      request_state = result(asked)["requestState"]

      resumed =
        call_tool(
          build_conn(),
          pat,
          "restore_backup",
          %{"id" => instance.id, "backup_run_id" => run.id},
          input_responses: %{
            "elicitation" => %{"action" => "accept", "content" => %{"confirm" => "no"}}
          },
          request_state: request_state,
          capabilities: @elicit_caps
        )

      assert tool_result_text(resumed) == "cancelled. Nothing was changed"

      assert_instance_status!(instance, :running)
      assert run_still_succeeded!(run.id)
      assert restore_runs!(instance.id) == []
    end

    test "without the elicitation capability the call is a protocol error, not a question", %{
      conn: conn
    } do
      {_user, instance, run, pat} = restorable!()

      conn =
        call_tool(conn, pat, "restore_backup", %{"id" => instance.id, "backup_run_id" => run.id})

      # A plain-JSON protocol error (no result frame, no question):
      # the capability gate names what was missing.
      assert conn.status == 400

      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert error["code"] == -32_021
      assert error["message"] == "Missing required client capability"
      assert error["data"]["requiredCapabilities"] == %{"elicitation" => %{}}
    end

    test "a backups:read-only token's direct call is unresolvable — the allowlist gate", %{
      conn: conn
    } do
      {user, instance, run, _pat} = restorable!()
      pat = ApiPat.mint!(user.email, ["backups:read"])

      conn =
        call_tool(conn, pat, "restore_backup", %{"id" => instance.id, "backup_run_id" => run.id},
          capabilities: @elicit_caps
        )

      # The filtered-out tool never reaches a handler: the protocol's
      # invalid-params error (the handler-level scope refusal is
      # scope_dispatch_test's).
      [%{"error" => error}] = sse_messages(conn)
      assert error["code"] == -32_602
    end
  end

  describe "destroy_instance resumed in-process" do
    test "a yes arm whose confirmed id no longer resolves is a tool error", %{conn: _conn} do
      {user, pat_row, _instance, _pat} = restorable_row!()

      Phantom.Test.expect_elicit(fn _elicit ->
        {:ok, %{"action" => "accept", "content" => %{"confirm" => "yes"}}}
      end)

      # The resumed session's state names a row that is not there —
      # the confirmed action's own authorized read refuses. The args
      # carry the schema-required id; the confirmed target rides the
      # state.
      base = confirmed_session(user, pat_row)

      session =
        Map.put(base, :state, %{step: :confirming_destroy, instance_id: Ecto.UUID.generate()})

      result =
        Phantom.Test.call_tool(session, :destroy_instance, %{"id" => "x", "confirm" => "yes"})

      assert tool_error_text(result) =~ "not found"
    end
  end

  describe "restore_backup resumed in-process (the yes arm needs the cluster stubs)" do
    setup :stub_restore_cluster

    test "answering yes runs the restore — the run row comes back", %{conn: _conn} do
      {user, pat_row, instance, run} = restorable_row!()

      Phantom.Test.expect_elicit(fn elicit ->
        assert elicit.message =~ "OVERWRITTEN"
        {:ok, %{"action" => "accept", "content" => %{"confirm" => "yes"}}}
      end)

      session = confirmed_session(user, pat_row)

      result =
        Phantom.Test.call_tool(session, :restore_backup, %{
          "id" => instance.id,
          "backup_run_id" => run.id
        })

      row = row!(result, "backup_run")
      assert row[:attributes][:kind] == "restore"
      assert row[:attributes][:status] == "running"
      assert row[:attributes][:restored_from] == "running"

      # The operation's own contract: the instance is mid-restore and
      # the restore-kind run row exists.
      assert_instance_status!(instance, :restoring)
      assert restore_runs!(instance.id) != []
    end

    test "answering no ends cancelled — the run row untouched", %{conn: _conn} do
      {user, pat_row, instance, run} = restorable_row!()

      Phantom.Test.expect_elicit(fn _elicit ->
        {:ok, %{"action" => "accept", "content" => %{"confirm" => "no"}}}
      end)

      session = confirmed_session(user, pat_row)

      result =
        Phantom.Test.call_tool(session, :restore_backup, %{
          "id" => instance.id,
          "backup_run_id" => run.id
        })

      assert result_text(result) == "cancelled. Nothing was changed"

      assert_instance_status!(instance, :running)
      assert run_still_succeeded!(run.id)
      assert restore_runs!(instance.id) == []
    end

    test "a decline (no answer at all) cancels the same way", %{conn: _conn} do
      {user, pat_row, instance, run} = restorable_row!()

      Phantom.Test.expect_elicit(fn _elicit ->
        {:ok, %{"action" => "decline"}}
      end)

      session = confirmed_session(user, pat_row)

      result =
        Phantom.Test.call_tool(session, :restore_backup, %{
          "id" => instance.id,
          "backup_run_id" => run.id
        })

      assert result_text(result) == "cancelled. Nothing was changed"
      assert restore_runs!(instance.id) == []
    end

    # The yes arm re-runs the ACTION with the confirmed inputs — a run
    # id that is not the newest successful backup gets the operation's
    # own fence refusal, from inside the resumed handler.
    test "a yes arm whose run is not restorable carries the operation's fence words", %{
      conn: _conn
    } do
      {user, pat_row, instance, run} = restorable_row!()

      Phantom.Test.expect_elicit(fn _elicit ->
        {:ok, %{"action" => "accept", "content" => %{"confirm" => "yes"}}}
      end)

      session = confirmed_session(user, pat_row)

      result =
        Phantom.Test.call_tool(session, :restore_backup, %{
          "id" => instance.id,
          "backup_run_id" => Enum.at([Ecto.UUID.generate()], 0)
        })

      assert result_text(result) =~ "not the latest successful backup"
      assert run_still_succeeded!(run.id)
      assert restore_runs!(instance.id) == []
    end
  end

  # --- destroy_instance ------------------------------------------------

  describe "destroy_instance over the transport" do
    test "the first call returns input_required naming the instance — row intact", %{
      conn: conn
    } do
      {_user, instance, pat} = destroyable!()

      conn =
        call_tool(conn, pat, "destroy_instance", %{"id" => instance.id},
          capabilities: @elicit_caps
        )

      result = result(conn)
      assert result["resultType"] == "input_required"
      assert is_binary(result["requestState"])

      assert %{"elicitation" => elicit} = result["inputRequests"]
      message = elicit["params"]["message"]
      assert message =~ "destroy instance #{instance.name} (#{instance.slug})"
      assert message =~ "All data is deleted"

      # Nothing destroyed yet.
      assert still_exists?(instance.id)
    end

    # A never-deployed row's teardown hard-deletes synchronously — no
    # cluster work — so the yes arm rides the live wire (encrypted
    # requestState in, resumed handler out) with no stubs.
    test "answering yes over the wire destroys the never-deployed row", %{conn: conn} do
      {_user, instance, pat} = destroyable!()

      asked =
        call_tool(conn, pat, "destroy_instance", %{"id" => instance.id},
          capabilities: @elicit_caps
        )

      request_state = result(asked)["requestState"]

      resumed =
        call_tool(
          build_conn(),
          pat,
          "destroy_instance",
          %{"id" => instance.id},
          input_responses: %{
            "elicitation" => %{"action" => "accept", "content" => %{"confirm" => "yes"}}
          },
          request_state: request_state,
          capabilities: @elicit_caps
        )

      # The truthful success shape (the review fix): teardown-queued
      # language — never a promise that the row is gone (a deployed
      # instance lingers in :deleting until teardown finishes).
      assert tool_result_text(resumed) =~ "destroy accepted"
      assert tool_result_text(resumed) =~ "never-deployed row is gone now"
      refute still_exists?(instance.id)
    end

    test "answering no over the wire cancels — the row survives", %{conn: conn} do
      {_user, instance, pat} = destroyable!()

      asked =
        call_tool(conn, pat, "destroy_instance", %{"id" => instance.id},
          capabilities: @elicit_caps
        )

      request_state = result(asked)["requestState"]

      resumed =
        call_tool(
          build_conn(),
          pat,
          "destroy_instance",
          %{"id" => instance.id},
          input_responses: %{
            "elicitation" => %{"action" => "accept", "content" => %{"confirm" => "no"}}
          },
          request_state: request_state,
          capabilities: @elicit_caps
        )

      assert tool_result_text(resumed) == "cancelled. Nothing was changed"
      assert still_exists?(instance.id)
    end

    test "a foreign id is a tool error before any question is asked", %{conn: conn} do
      {_user, _instance, pat} = destroyable!()
      foreign_id = Enum.at([Ecto.UUID.generate()], 0)

      destroy_conn =
        call_tool(conn, pat, "destroy_instance", %{"id" => foreign_id},
          capabilities: @elicit_caps
        )

      assert tool_result_text(destroy_conn) =~ "not found"

      restore_conn =
        call_tool(
          build_conn(),
          pat,
          "restore_backup",
          %{"id" => foreign_id, "backup_run_id" => foreign_id},
          capabilities: @elicit_caps
        )

      assert tool_result_text(restore_conn) =~ "not found"
    end

    test "a garbage run id is refused by the schema — no wasted confirm round trip", %{
      conn: conn
    } do
      {_user, instance, _run, pat} = restorable!()

      # A run id that could never satisfy the action's uuid argument:
      # the input schema's pattern refuses it before the question.
      conn =
        call_tool(conn, pat, "restore_backup", %{"id" => instance.id, "backup_run_id" => "nope"},
          capabilities: @elicit_caps
        )

      assert tool_result_text(conn) =~ "Invalid tool arguments"
    end
  end

  # --- the harness -----------------------------------------------------

  # The resume clauses read the confirmed target from session.state —
  # mirror connect/2's assigns (the principal binding included).
  defp confirmed_session(user, pat_row) do
    Phantom.Test.build_session(Router,
      assigns: %{user: user, pat: pat_row, request_state_principal: user.id},
      protocol_version: "2026-07-28"
    )
  end

  defp row!(%{structuredContent: %{type: type} = row}, type), do: row

  defp tool_error_text(%{isError: true, content: [%{text: text}]}), do: text
  defp tool_error_text(other), do: flunk("expected a tool error, got: #{inspect(other)}")

  defp tool_result_text(conn) do
    %{"content" => [%{"text" => text}]} = result(conn)
    text
  end

  defp result_text(%{content: [%{text: text}]}), do: text

  # --- fixtures ---------------------------------------------------------

  defp pat_row!(raw) do
    hash = PersonalAccessToken.token_hash(raw)
    {:ok, pat} = PersonalAccessToken.get_by_token_hash(hash, authorize?: false)
    pat
  end

  defp full_scopes_pat! do
    families = [:instances, :backups, :gateways]

    scopes =
      Enum.flat_map(families, fn family -> ["#{family}:write", "#{family}:read"] end)

    {user, raw} = ApiPat.member!(scopes ++ ["wallet:read", "catalog:read"])
    {user, pat_row!(raw), raw}
  end

  # A paid member's deployed running instance with a configured,
  # succeeded backup run — the restorable population.
  defp restorable! do
    {user, _pat_row, pat} = full_scopes_pat!()
    BillingFixtures.mark_user_paid!(user)

    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()

    instance = running_instance!(version, user)

    backup_setting!(instance)
    run = succeeded_run!(instance)

    {user, instance, run, pat}
  end

  defp restorable_row! do
    {user, pat_row, _pat} = full_scopes_pat!()
    BillingFixtures.mark_user_paid!(user)

    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()

    instance = running_instance!(version, user)

    backup_setting!(instance)
    run = succeeded_run!(instance)

    {user, pat_row, instance, run}
  end

  defp running_instance!(version, user) do
    base = InstanceFixtures.instance!(version, user)

    base
    |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{base.id}")
    |> InstanceFixtures.walk_to!(:running)
  end

  defp destroyable! do
    {user, _pat_row, pat} = full_scopes_pat!()
    BillingFixtures.mark_user_paid!(user)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance = InstanceFixtures.instance!(version, user)

    {user, instance, pat}
  end

  defp backup_setting!(instance) do
    BackupSetting
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        prefix: "fluxvale/app",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        retention_keep: 7
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # The restore op test's two-write shape: create, then finalize the
  # outcome fields (:create does not accept them).
  defp succeeded_run!(instance) do
    run =
      BackupRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          instance_id: instance.id,
          kind: :scheduled,
          status: :pending,
          started_at: DateTime.utc_now()
        },
        authorize?: false
      )
      |> Ash.create!()

    run
    |> Ash.Changeset.for_update(
      :update,
      %{
        status: :succeeded,
        snapshot_id: String.duplicate("a", 64),
        finished_at: DateTime.utc_now()
      },
      authorize?: false
    )
    |> Ash.update!()
  end

  # --- mutation probes (authorize?: false — precondition reads) -------

  defp still_exists?(instance_id) do
    match?({:ok, _}, Instance.get_by_id(instance_id, authorize?: false))
  end

  defp assert_instance_status!(instance, expected) do
    {:ok, fresh} = Instance.get_by_id(instance.id, authorize?: false)
    assert fresh.status == expected
  end

  defp run_still_succeeded!(run_id) do
    run = Ash.get!(BackupRun, run_id, authorize?: false)
    assert run.status == :succeeded
    run
  end

  defp restore_runs!(instance_id) do
    BackupRun
    |> Ash.Query.filter(instance_id == ^instance_id and kind == :restore)
    |> Ash.read!(authorize?: false)
  end

  # --- the restore yes arm's cluster (backup_route_test's own set) ----

  defp stub_restore_cluster(_context) do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

    stub(Deployment, :get, fn _kc, _ns, "app" ->
      {:ok, %{"metadata" => %{"name" => "app"}, "status" => %{"replicas" => 0}}}
    end)

    stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    :ok
  end
end

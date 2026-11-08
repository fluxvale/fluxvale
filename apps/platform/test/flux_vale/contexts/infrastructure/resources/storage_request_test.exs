defmodule FluxVale.Infrastructure.StorageRequestTest do
  @moduledoc """
  The StorageRequest domain contract (#250, ADR-0046): the create's
  boundary validations and advisory quote, the one-open-request
  invariant, the four-state machine's actions and their gates, the
  policy arms (member org-scoped reads/writes, admin decisions, system
  marks), and the queue read's filter/search/count.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Accounts
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Infrastructure.Operations.ResizePreview
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.StorageRequestFixtures

  setup do
    # The capability probe resolves the cluster's kubeconfig before the
    # StorageClass read (the grow-storage suite's stub shape).
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    :ok
  end

  defp user!, do: AccountsFixtures.user!()

  # A member's instance on a fresh catalog (storage 10 by default), with
  # a namespace pinned so the apply path sees a cluster-managed row.
  defp instance!(user, opts \\ []) do
    storage_gb = Keyword.get(opts, :storage_gb, 10)

    version =
      if Keyword.get(opts, :sizeless, false) do
        sizeless_version!()
      else
        version_opts = Keyword.get(opts, :version_opts, [])

        app_version_opts =
          Keyword.merge([default_storage_gb: storage_gb, monthly_cents: 100], version_opts)

        InstanceFixtures.app_version!(app_version_opts)
      end

    ensure_cluster!()

    instance = InstanceFixtures.instance!(version, user)
    InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")
  end

  # One cluster row per test (ResolveCluster's exactly-one invariant):
  # several instances in one test share it.
  defp ensure_cluster! do
    case Ash.read(FluxVale.Infrastructure.Cluster, authorize?: false) do
      {:ok, [_head | _tail]} -> :ok
      {:ok, []} -> InstanceFixtures.local_cluster!()
    end
  end

  # The pre-#125 drift shape (the resize preview's own precedent): a
  # version with no recommended size, unpriceable by design.
  defp sizeless_version! do
    version = InstanceFixtures.app_version!()
    app = Ash.load!(version, :app, authorize?: false).app
    n = rem(System.unique_integer([:positive]), 100)

    Ash.Seed.seed!(FluxVale.Catalog.AppVersion, %{
      version: "0.9.#{n}",
      image: "test/image:0.9",
      port: 3000,
      app_id: app.id
    })
  end

  defp stopped!(user, opts \\ []) do
    user
    |> instance!(opts)
    |> InstanceFixtures.walk_to!(:stopped)
  end

  defp pending_request!(user, attrs \\ %{}) do
    instance = instance!(user)
    StorageRequestFixtures.request!(instance, user, attrs)
  end

  defp stopped_request!(user, attrs) do
    instance = stopped!(user)
    StorageRequestFixtures.request!(instance, user, attrs)
  end

  defp personal_org!(user) do
    {:ok, org} = Accounts.personal_org_for_user(user.id, authorize?: false)
    org
  end

  # The one legal approve precondition shared by the happy-path tests.
  defp allow_expansion!,
    do: stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

  defp error_messages({:error, error}), do: Exception.message(error)

  # --- create ---------------------------------------------------------

  describe "create :request" do
    test "snapshots the org/current allocation, trims the reason, and quotes both figures" do
      user = user!()
      instance = instance!(user)

      request =
        StorageRequestFixtures.request!(instance, user, %{
          requested_gb: 150,
          reason: "  Need room for archives  "
        })

      assert request.status == :requested
      assert request.instance_id == instance.id
      assert request.organization_id == instance.organization_id
      assert request.current_storage_gb == instance.storage_gb
      assert request.requested_gb == 150
      assert request.reason == "Need room for archives"
      assert request.requested_by_user_id == user.id
      assert request.decided_at == nil
      assert request.apply_error == nil

      assert {:ok, %{running_cents: target}} =
               ResizePreview.call(instance, %{
                 cpu_cores: instance.cpu_cores,
                 memory_mb: instance.memory_mb,
                 storage_gb: 150
               })

      assert {:ok, %{running_cents: current}} =
               ResizePreview.call(instance, %{
                 cpu_cores: instance.cpu_cores,
                 memory_mb: instance.memory_mb,
                 storage_gb: instance.storage_gb
               })

      assert request.quoted_monthly_cents == target
      assert request.quoted_current_cents == current
      assert target > current
    end

    test "an unpriced version quotes nil — the rate is confirmed at approval" do
      user = user!()
      instance = instance!(user, sizeless: true)

      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      assert request.quoted_monthly_cents == nil
      assert request.quoted_current_cents == nil
    end

    test "a failed pricing read quotes nil — the advisory never blocks the request" do
      Mimic.copy(ResizePreview)
      stub(ResizePreview, :call, fn _instance, _allocation -> {:error, :unavailable} end)

      user = user!()
      instance = instance!(user)

      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      assert request.quoted_monthly_cents == nil
      assert request.quoted_current_cents == nil
    end

    test "a target at or below the self-service threshold is refused" do
      user = user!()
      instance = instance!(user)

      error =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: instance.id, requested_gb: 100, reason: "Below the line"},
          actor: user
        )
        |> Ash.create()
        |> error_messages()

      assert error =~ "self-service storage covers up to 100 GB — resize instead"
    end

    test "a target not above the current allocation is refused" do
      user = user!()
      instance = instance!(user, storage_gb: 150)

      error =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: instance.id, requested_gb: 150, reason: "No change"},
          actor: user
        )
        |> Ash.create()
        |> error_messages()

      assert error =~ "requested storage must be above the current 150 GB"
    end

    test "a target above the attachable maximum is refused" do
      user = user!()
      instance = instance!(user)

      error =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: instance.id, requested_gb: 7_601, reason: "Too big"},
          actor: user
        )
        |> Ash.create()
        |> error_messages()

      assert error =~ "requested storage exceeds the 7600 GB maximum"
    end

    test "a second open request is refused — the requested arm" do
      user = user!()
      instance = instance!(user)

      StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      error =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: instance.id, requested_gb: 200, reason: "Again"},
          actor: user
        )
        |> Ash.create()
        |> error_messages()

      assert error =~ "this instance already has an open storage request"
    end

    test "a second open request is refused — the approved arm" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      instance = stopped!(user)
      allow_expansion!()

      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)
      assert approved.status == :approved

      error =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: instance.id, requested_gb: 200, reason: "Again"},
          actor: user
        )
        |> Ash.create()
        |> error_messages()

      assert error =~ "this instance already has an open storage request"
    end

    test "a deleting instance is refused" do
      user = user!()
      instance = stopped!(user)
      deleting = InstanceFixtures.pin!(instance, status: :deleting)

      error =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: deleting.id, requested_gb: 150, reason: "Gone"},
          actor: user
        )
        |> Ash.create()
        |> error_messages()

      assert error =~ "cannot request storage for an instance in deleting state"
    end

    test "a lost instance is refused" do
      user = user!()
      instance = stopped!(user)
      lost = InstanceFixtures.pin!(instance, status: :lost)

      error =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: lost.id, requested_gb: 150, reason: "Lost"},
          actor: user
        )
        |> Ash.create()
        |> error_messages()

      assert error =~ "cannot request storage for an instance in lost state"
    end

    test "a missing target is the attribute's required error, not a boundary noise" do
      user = user!()
      instance = instance!(user)

      result =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: instance.id, reason: "Forgot the amount"},
          actor: user
        )
        |> Ash.create()

      assert {:error, error} = result
      message = Exception.message(error)
      assert message =~ "requested_gb"
      refute message =~ "self-service storage"
    end

    test "a create without an actor attributes no requester" do
      user = user!()
      instance = instance!(user)

      result =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: instance.id, requested_gb: 150, reason: "System bootstrap"},
          authorize?: false
        )
        |> Ash.create()

      assert {:error, error} = result
      assert Exception.message(error) =~ "requested_by_user_id"
    end

    test "a stranger's instance is not found — never a queue row" do
      owner = user!()
      stranger = user!()
      instance = instance!(owner)

      result =
        StorageRequest
        |> Ash.Changeset.for_create(
          :request,
          %{instance_id: instance.id, requested_gb: 150, reason: "Not mine"},
          actor: stranger
        )
        |> Ash.create()

      assert {:error, error} = result
      assert Exception.message(error) =~ "instance not found"
    end
  end

  # --- reads ----------------------------------------------------------

  describe "reads" do
    test "for_instance returns one instance's requests newest first" do
      user = user!()
      admin = AccountsFixtures.platform_admin!()
      first = instance!(user)
      other = instance!(user)

      older = StorageRequestFixtures.request!(first, user, %{requested_gb: 150})
      {:ok, _rejected} = StorageRequest.reject(older, %{rejection_reason: "No"}, actor: admin)
      newest = StorageRequestFixtures.request!(first, user, %{requested_gb: 200})
      beyond = StorageRequestFixtures.request!(other, user, %{requested_gb: 300})

      assert {:ok, requests} = StorageRequest.for_instance(first.id, actor: user)
      assert Enum.map(requests, & &1.id) == [newest.id, older.id]
      refute Enum.any?(requests, &(&1.id == beyond.id))
    end

    test "for_instance caps the history at the action's bound" do
      user = user!()
      instance = instance!(user)
      created = DateTime.add(DateTime.utc_now(), -3_600, :second)

      # Bulk history the create action cannot produce (one open request
      # per instance): seed closed rows with distinct clocks.
      for offset <- 1..51 do
        Ash.Seed.seed!(StorageRequest, %{
          instance_id: instance.id,
          organization_id: instance.organization_id,
          requested_gb: 150,
          current_storage_gb: instance.storage_gb,
          reason: "Seeded history #{offset}",
          status: :rejected,
          requested_by_user_id: user.id,
          created_at: DateTime.add(created, offset, :second)
        })
      end

      assert {:ok, requests} = StorageRequest.for_instance(instance.id, authorize?: false)
      assert length(requests) == 50
    end

    test "a member reads their own org's request; another org's is not found" do
      owner = user!()
      stranger = user!()
      instance = instance!(owner)
      request = StorageRequestFixtures.request!(instance, owner)

      assert {:ok, read} = StorageRequest.get_by_id(request.id, actor: owner)
      assert read.id == request.id

      assert {:error, error} = StorageRequest.get_by_id(request.id, actor: stranger)
      assert Exception.message(error) =~ "not found"
    end

    test "a platform admin reads any org's request" do
      user = user!()
      admin = AccountsFixtures.platform_admin!()
      request = pending_request!(user)

      assert {:ok, read} = StorageRequest.get_by_id(request.id, actor: admin)
      assert read.id == request.id
    end

    test "for_instance filters another org's rows to an empty list" do
      owner = user!()
      stranger = user!()
      instance = instance!(owner)
      StorageRequestFixtures.request!(instance, owner)

      assert {:ok, []} = StorageRequest.for_instance(instance.id, actor: stranger)
    end

    test "the queue filters by status and counts the full set" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()

      requested_a = pending_request!(user, %{requested_gb: 150})
      requested_b = pending_request!(user, %{requested_gb: 200})
      rejected = pending_request!(user, %{requested_gb: 300})
      {:ok, _rejected} = StorageRequest.reject(rejected, %{rejection_reason: "No"}, actor: admin)

      assert {:ok, page} = StorageRequest.queue(%{status: :requested}, actor: admin)
      assert page.count == 2

      ids = Enum.map(page.results, & &1.id)
      assert Enum.sort(ids) == Enum.sort([requested_a.id, requested_b.id])
      refute rejected.id in ids

      # Newest first.
      assert [newest | _rest] = page.results
      assert newest.id == requested_b.id
    end

    test "the queue searches the reason text and the ids" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()

      archives =
        pending_request!(user, %{
          requested_gb: 150,
          reason: "Need room for archives"
        })

      other =
        pending_request!(user, %{
          requested_gb: 200,
          reason: "Video exports"
        })

      assert {:ok, page} = StorageRequest.queue(%{search: "ARCHIV"}, actor: admin)
      assert Enum.map(page.results, & &1.id) == [archives.id]

      assert {:ok, page} = StorageRequest.queue(%{search: archives.id}, actor: admin)
      assert Enum.map(page.results, & &1.id) == [archives.id]

      assert {:ok, page} = StorageRequest.queue(%{search: other.instance_id}, actor: admin)
      assert Enum.map(page.results, & &1.id) == [other.id]

      assert {:ok, page} = StorageRequest.queue(%{search: "no-such-reason"}, actor: admin)
      assert page.results == []

      assert {:ok, page} = StorageRequest.queue(%{search: ""}, actor: admin)
      assert page.count == 2
    end

    test "a member cannot read the queue" do
      user = user!()
      pending_request!(user)

      assert {:error, %Ash.Error.Forbidden{}} = StorageRequest.queue(%{}, actor: user)
    end
  end

  # --- approve --------------------------------------------------------

  describe "approve" do
    test "records the durable decision and touches no cluster state" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      instance = stopped!(user)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      # No cluster I/O: the capability probe is the only (cached) read.
      allow_expansion!()
      reject(PersistentVolumeClaim, :upsert, 4)
      reject(ResourceQuota, :create, 4)

      before = DateTime.utc_now()
      assert {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      assert approved.status == :approved
      assert approved.decided_by_user_id == admin.id
      assert DateTime.compare(approved.decided_at, before) in [:gt, :eq]
      assert approved.applied_at == nil
      assert approved.apply_error == nil
    end

    test "only a requested row can be approved" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      instance = stopped!(user)
      allow_expansion!()

      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      assert {:error, error} = StorageRequest.approve(approved, %{}, actor: admin)
      assert Exception.message(error) =~ "only a requested storage request can be approved"
    end

    test "an instance in a non-growth status is refused" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      instance = instance!(user)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      assert {:error, error} = StorageRequest.approve(request, %{}, actor: admin)

      assert Exception.message(error) =~
               "cannot approve storage for an instance in pending state"
    end

    test "a stale target is refused — reject instead" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      instance = stopped!(user)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      # A resize between request and approve: the target is no longer a
      # growth.
      grown = InstanceFixtures.pin!(instance, storage_gb: 150)

      assert {:error, error} = StorageRequest.approve(request, %{}, actor: admin)
      assert Exception.message(error) =~ "the instance already has 150 GB — reject this request"

      # The row stayed requested (the instance row is not part of this).
      assert {:ok, still} = StorageRequest.get_by_id(request.id, actor: admin)
      assert still.status == :requested
      assert grown.storage_gb == 150
    end

    test "capability false is refused with the product boundary" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})

      stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, false} end)

      assert {:error, error} = StorageRequest.approve(request, %{}, actor: admin)
      assert Exception.message(error) =~ "storage can't be expanded on this cluster yet"
    end

    test "a probe error says try again, not the capability no" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})

      stub(StorageClass, :default_allows_expansion?, fn _kc ->
        {:error, Error.connection_error("api server on fire")}
      end)

      assert {:error, error} = StorageRequest.approve(request, %{}, actor: admin)
      assert Exception.message(error) =~ "storage expansion check failed — try again"
      refute Exception.message(error) =~ "storage can't be expanded on this cluster yet"
    end

    test "an unfunded org is refused — top up or reject with feedback" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()

      org = personal_org!(user)
      BillingFixtures.drain_wallet!(org)

      assert {:error, error} = StorageRequest.approve(request, %{}, actor: admin)

      assert Exception.message(error) =~
               "the organization's wallet isn't funded — top it up before approving"
    end

    test "a member cannot approve" do
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()

      assert {:error, %Ash.Error.Forbidden{}} = StorageRequest.approve(request, %{}, actor: user)
    end

    test "a vanished instance is refused honestly" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()

      %StorageRequest{} =
        request =
        stopped_request!(user, %{requested_gb: 150})

      vanished = %StorageRequest{request | instance_id: Ash.UUID.generate()}

      assert {:error, error} = StorageRequest.approve(vanished, %{}, actor: admin)
      assert Exception.message(error) =~ "the instance no longer exists"
    end

    test "an operator-less approval is refused by the guard" do
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})

      assert {:error, error} = StorageRequest.approve(request, %{}, authorize?: false)
      assert Exception.message(error) =~ "an operator must approve the request"
    end
  end

  # --- reject ---------------------------------------------------------

  describe "reject" do
    test "a requested row is rejected with the member-visible feedback" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = pending_request!(user, %{requested_gb: 150})

      assert {:ok, rejected} =
               StorageRequest.reject(
                 request,
                 %{rejection_reason: "Capacity isn't available right now"},
                 actor: admin
               )

      assert rejected.status == :rejected
      assert rejected.rejection_reason == "Capacity isn't available right now"
      assert rejected.decided_by_user_id == admin.id
      assert rejected.decided_at

      assert {:ok, read} = StorageRequest.get_by_id(rejected.id, actor: user)
      assert read.rejection_reason == "Capacity isn't available right now"
    end

    test "an approved row is rejected — the unappliable escape hatch" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()

      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      assert {:ok, rejected} =
               StorageRequest.reject(approved, %{rejection_reason: "Capacity can't be attached"},
                 actor: admin
               )

      assert rejected.status == :rejected
    end

    test "feedback is required" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = pending_request!(user, %{requested_gb: 150})

      assert {:error, nil_feedback} = StorageRequest.reject(request, %{}, actor: admin)
      assert Exception.message(nil_feedback) =~ "rejection feedback is required"

      assert {:error, blank_feedback} =
               StorageRequest.reject(request, %{rejection_reason: "   "}, actor: admin)

      assert Exception.message(blank_feedback) =~ "rejection feedback is required"
    end

    test "a closed request cannot be rejected" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = pending_request!(user, %{requested_gb: 150})
      {:ok, rejected} = StorageRequest.reject(request, %{rejection_reason: "No"}, actor: admin)

      assert {:error, error} =
               StorageRequest.reject(rejected, %{rejection_reason: "Still no"}, actor: admin)

      assert Exception.message(error) =~ "only an open storage request can be rejected"
    end

    test "an operator-less rejection is refused by the guard" do
      user = user!()
      request = pending_request!(user, %{requested_gb: 150})

      assert {:error, error} =
               StorageRequest.reject(request, %{rejection_reason: "No"}, authorize?: false)

      assert Exception.message(error) =~ "an operator must reject the request"
    end

    test "a member cannot reject" do
      user = user!()
      request = pending_request!(user, %{requested_gb: 150})

      assert {:error, %Ash.Error.Forbidden{}} =
               StorageRequest.reject(request, %{rejection_reason: "No"}, actor: user)
    end
  end

  # --- retry ----------------------------------------------------------

  describe "retry_apply" do
    test "an approved request passes the retry gate without a decision write" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()

      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      assert {:ok, retried} = StorageRequest.retry_apply(approved, %{}, actor: admin)
      assert retried.status == :approved
      assert retried.decided_at == approved.decided_at
      assert retried.decided_by_user_id == approved.decided_by_user_id
    end

    test "a non-approved request is refused" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = pending_request!(user, %{requested_gb: 150})

      assert {:error, error} = StorageRequest.retry_apply(request, %{}, actor: admin)
      assert Exception.message(error) =~ "only an approved storage request can be retried"
    end

    test "a member cannot retry" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               StorageRequest.retry_apply(approved, %{}, actor: user)
    end
  end

  # --- system marks ---------------------------------------------------

  describe "mark_applied" do
    test "an approved request becomes applied with the stamp, clearing the error" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      {:ok, failed} =
        StorageRequest.mark_apply_failed(approved, %{error: "boom"}, authorize?: false)

      assert {:ok, applied} = StorageRequest.mark_applied(failed, %{}, authorize?: false)
      assert applied.status == :applied
      assert applied.applied_at
      assert applied.apply_error == nil
    end

    test "a non-approved request is refused" do
      user = user!()
      request = pending_request!(user, %{requested_gb: 150})

      assert {:error, error} = StorageRequest.mark_applied(request, %{}, authorize?: false)
      assert Exception.message(error) =~ "only an approved storage request can be marked applied"
    end
  end

  describe "mark_apply_failed" do
    test "an approved request stays approved with the honest error" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      assert {:ok, failed} =
               StorageRequest.mark_apply_failed(approved, %{error: "the PVC said no"},
                 authorize?: false
               )

      assert failed.status == :approved
      assert failed.apply_error == "the PVC said no"
      assert failed.applied_at == nil
    end

    test "a non-approved request is refused" do
      user = user!()
      request = pending_request!(user, %{requested_gb: 150})

      assert {:error, error} =
               StorageRequest.mark_apply_failed(request, %{error: "no"}, authorize?: false)

      assert Exception.message(error) =~
               "only an approved storage request can record an apply failure"
    end

    test "an actor is denied — the system marks have no policy arm" do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               StorageRequest.mark_apply_failed(approved, %{error: "no"}, actor: admin)
    end
  end

  # --- optimistic locking ---------------------------------------------

  describe "optimistic locking" do
    setup do
      admin = AccountsFixtures.platform_admin!()
      user = user!()
      request = stopped_request!(user, %{requested_gb: 150})
      allow_expansion!()
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      %{admin: admin, approved: approved}
    end

    test "a stale reject cannot overwrite a newer apply mark", %{
      admin: admin,
      approved: approved
    } do
      {:ok, applied} = StorageRequest.mark_applied(approved, %{}, authorize?: false)

      assert {:error, error} =
               StorageRequest.reject(
                 approved,
                 %{rejection_reason: "Too late"},
                 actor: admin
               )

      assert Exception.message(error) =~ "stale record"

      assert {:ok, row} = StorageRequest.get_by_id(applied.id, authorize?: false)
      assert row.status == :applied
      assert row.rejection_reason == nil
    end

    test "a stale retry cannot overwrite a newer rejection", %{
      admin: admin,
      approved: approved
    } do
      {:ok, rejected} =
        StorageRequest.reject(approved, %{rejection_reason: "No capacity"}, actor: admin)

      assert {:error, error} = StorageRequest.retry_apply(approved, %{}, actor: admin)
      assert Exception.message(error) =~ "stale record"

      assert {:ok, row} = StorageRequest.get_by_id(rejected.id, authorize?: false)
      assert row.status == :rejected
    end

    test "stale apply marks cannot overwrite a newer rejection", %{
      admin: admin,
      approved: approved
    } do
      {:ok, rejected} =
        StorageRequest.reject(approved, %{rejection_reason: "No capacity"}, actor: admin)

      assert {:error, applied_error} =
               StorageRequest.mark_applied(approved, %{}, authorize?: false)

      assert Exception.message(applied_error) =~ "stale record"

      assert {:error, failed_error} =
               StorageRequest.mark_apply_failed(approved, %{error: "boom"}, authorize?: false)

      assert Exception.message(failed_error) =~ "stale record"

      assert {:ok, row} = StorageRequest.get_by_id(rejected.id, authorize?: false)
      assert row.status == :rejected
      assert row.applied_at == nil
      assert row.apply_error == nil
    end
  end
end

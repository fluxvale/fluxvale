defmodule FluxVale.Infrastructure.Operations.RecordCustodyEventTest do
  @moduledoc """
  The guarded append (#597 S2, the Api.RecordAuditEvent posture): a
  failed write is swallowed — `:ok` always — because every caller
  rides a success path that already happened. Off-enum kinds fail
  validation into the guard, never into the caller's face.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Infrastructure.Operations.RecordCustodyEvent
  alias FluxVale.Infrastructure.PocketIdCustodyEvent
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    # Instance create rides the funded-wallet gate (#124).
    BillingFixtures.funded_wallet!(org: org)
    version = InstanceFixtures.app_version!()
    instance = InstanceFixtures.instance!(version, owner)

    {:ok, org: org, instance: instance}
  end

  test "appends the row exactly as given", %{org: org, instance: instance} do
    assert :ok =
             RecordCustodyEvent.call(%{
               organization_id: org.id,
               instance_id: instance.id,
               kind: :used,
               purpose: "verification",
               actor_id: nil
             })

    assert {:ok, [%PocketIdCustodyEvent{kind: :used, purpose: "verification"}]} =
             PocketIdCustodyEvent.for_instance(instance.id, authorize?: false)
  end

  # The guard's teeth (RecordAuditEvent's test stance): an invalid
  # attrs map logs and returns :ok — the audited operation survives.
  test "an off-enum kind is logged and swallowed, never raised", %{
    org: org,
    instance: instance
  } do
    assert :ok =
             RecordCustodyEvent.call(%{
               organization_id: org.id,
               instance_id: instance.id,
               kind: :explode
             })

    assert {:ok, []} = PocketIdCustodyEvent.for_instance(instance.id, authorize?: false)
  end
end

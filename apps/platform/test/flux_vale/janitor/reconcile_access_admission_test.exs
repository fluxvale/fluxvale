defmodule FluxVale.Janitor.ReconcileAccessAdmissionTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Janitor.ReconcileAccessAdmission

  test "perform/1 runs the pass through the Infrastructure seam" do
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    # The cron-triggered entry point, exercised directly — the business
    # logic is Infrastructure.reconcile_access_admission/1 (own suite
    # next door). No pairings exist here: an empty pass.
    assert {:ok, %{checked: 0, converged: 0}} = ReconcileAccessAdmission.perform(%Oban.Job{})
  end
end

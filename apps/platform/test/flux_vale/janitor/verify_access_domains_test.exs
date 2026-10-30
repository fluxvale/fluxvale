defmodule FluxVale.Janitor.VerifyAccessDomainsTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Janitor.VerifyAccessDomains

  test "perform/1 runs the pass through the Infrastructure seam" do
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    # The cron-triggered entry point, exercised directly — the business
    # logic is Infrastructure.verify_access_domains/1 (own suite next
    # door). No domains exist here: an empty pass.
    assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
             VerifyAccessDomains.perform(%Oban.Job{})
  end
end

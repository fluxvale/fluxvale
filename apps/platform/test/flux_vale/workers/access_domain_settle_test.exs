defmodule FluxVale.Workers.AccessDomainSettleTest do
  @moduledoc false

  # The cron entry point (ADR-0040 §11): every serving custom domain,
  # one settle each. The settle's own suite covers the math; this
  # covers the walk's selection (the arms are the billing switch) and
  # the fail-loud contract (one bad domain fails the tick, the others
  # still settle).

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.Workers.AccessDomainSettle

  require Ash.Query

  setup do
    # Domain registration issues the verification Certificate (the
    # claim tests' stubs).
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)

    :ok
  end

  test "perform/1 settles every serving custom domain — and nothing else" do
    verified_org = funded_org!()
    _verified = verified_domain!(verified_org)

    attention_org = funded_org!()
    attention = verified_domain!(attention_org)

    _attention =
      Ash.update!(attention, %{}, action: :mark_needs_attention, authorize?: false)

    platform_org = funded_org!()

    AccessDomain.mint_platform!(
      %{domain: "fluxvale-#{System.unique_integer()}.test", organization_id: platform_org.org.id},
      authorize?: false
    )

    assert :ok = AccessDomainSettle.perform(%Oban.Job{})

    # Both serving rows armed their anchors (the settle ran); the
    # platform row did not (never on the arms).
    assert anchor_armed?(org_domain(verified_org.org.id))
    assert anchor_armed?(org_domain(attention_org.org.id))
    platform_domain = org_domain(platform_org.org.id)
    refute anchor_armed?(platform_domain)
  end

  test "a failing domain is skipped — the job still fails so Oban retries" do
    good_org = funded_org!()
    good_domain = verified_domain!(good_org)

    bad_org = funded_org!()
    bad_domain = verified_domain!(bad_org)

    # A full open interval, so the tick actually reaches the posting.
    month_ago = DateTime.add(DateTime.utc_now(), -2_629_746, :second)
    pin_anchor!(good_domain, month_ago)
    pin_anchor!(bad_domain, month_ago)

    # The debit for the bad org's wallet refuses; the good org's
    # settle is untouched (isolation, not abort-on-first).
    stub(Billing, :debit_wallet, fn wallet, _micros, _opts ->
      if wallet.organization_id == bad_org.org.id do
        {:error, :forced}
      else
        {:ok, :accrued}
      end
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, "access-domain settle failed for 1 domain(s)"} =
                 AccessDomainSettle.perform(%Oban.Job{})
      end)

    assert log =~ "settle failed"

    # The good domain's anchor advanced to (about) now; the bad one's
    # settle rolled back to its pinned window.
    good = org_domain(good_org.org.id)
    assert DateTime.diff(DateTime.utc_now(), good.metering_since, :second) < 60

    bad = org_domain(bad_org.org.id)
    assert DateTime.diff(bad.metering_since, month_ago, :second) < 60
  end

  test "a crashing settle is isolated — logged, counted, the tick still fails" do
    good_org = funded_org!()
    good_domain = verified_domain!(good_org)

    bad_org = funded_org!()
    bad_domain = verified_domain!(bad_org)

    month_ago = DateTime.add(DateTime.utc_now(), -2_629_746, :second)
    pin_anchor!(good_domain, month_ago)
    pin_anchor!(bad_domain, month_ago)

    stub(Billing, :debit_wallet, fn wallet, _micros, _opts ->
      if wallet.organization_id == bad_org.org.id do
        raise "kaboom"
      else
        {:ok, :accrued}
      end
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, "access-domain settle failed for 1 domain(s)"} =
                 AccessDomainSettle.perform(%Oban.Job{})
      end)

    assert log =~ "settle crashed"

    # The good domain still settled through the crash.
    good = org_domain(good_org.org.id)
    assert DateTime.diff(DateTime.utc_now(), good.metering_since, :second) < 60
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp funded_org! do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    %{org: org, owner: owner}
  end

  defp verified_domain!(funded) do
    {:ok, domain} =
      Infrastructure.register_access_domain(
        %{domain: "apps-#{System.unique_integer()}.customer.com"},
        actor: funded.owner
      )

    Ash.update!(domain, %{cert_secret_ref: "cert-secret"},
      action: :mark_verified,
      authorize?: false
    )
  end

  # Settlement's cursor is the settle's own write; staging it here
  # uses the system action that owns it (the settle tests' stance).
  defp pin_anchor!(domain, at) do
    domain
    |> Ash.Changeset.for_update(:settle_anchors, %{metering_since: at}, authorize?: false)
    |> Ash.update!()
  end

  defp org_domain(org_id) do
    AccessDomain
    |> Ash.Query.filter(organization_id == ^org_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp anchor_armed?(nil), do: false
  defp anchor_armed?(domain), do: domain.metering_since != nil
end

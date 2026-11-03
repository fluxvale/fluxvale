defmodule FluxVale.Workers.StaleTopupSweepTest do
  @moduledoc false

  # The cron entry point (#364): one expiry pass per hour. The
  # operation's suite covers the policy; this covers the plumbing and
  # the fail-loud contract (an error or crash fails the hour's job and
  # Oban retries).

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.Workers.StaleTopupSweep

  test "perform/1 expires the stale rows and answers :ok" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    # Aged pending row: created_at is a write-time stamp — no action
    # backdates it — the sanctioned Ash.seed! case.
    seeded =
      Ash.Seed.seed!(Topup, %{
        organization_id: org.id,
        amount_cents: 500,
        payment_request_id: "pr_stale",
        created_at: DateTime.add(DateTime.utc_now(), -25 * 3600, :second),
        updated_at: DateTime.utc_now()
      })

    assert :ok = StaleTopupSweep.perform(%Oban.Job{})

    reloaded = Topup.get_by_id!(seeded.id, authorize?: false)
    assert reloaded.status == :expired
  end

  test "perform/1 answers :ok on an empty pass" do
    assert :ok = StaleTopupSweep.perform(%Oban.Job{})
  end

  test "an error tuple fails the job — Oban retries the hour" do
    stub(Billing, :expire_stale_topups, fn -> {:error, :boom} end)

    assert {:error, :boom} = StaleTopupSweep.perform(%Oban.Job{})
  end

  test "a crash in the sweep fails the job (one bulk statement — nothing partial)" do
    stub(Billing, :expire_stale_topups, fn -> raise "kaboom" end)

    assert {:error, %RuntimeError{message: "kaboom"}} = StaleTopupSweep.perform(%Oban.Job{})
  end
end

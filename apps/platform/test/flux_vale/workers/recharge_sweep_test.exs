defmodule FluxVale.Workers.RechargeSweepTest do
  @moduledoc """
  The cron entry point (#829 L2): plumbing only. The sweep's own suite
  covers the decisions and the per-org isolation; this covers the
  delegation and the fail-loud contract (a failed pass fails the job,
  so Oban retries the hour).
  """

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Billing
  alias FluxVale.Workers.RechargeSweep

  test "perform/1 delegates to the operation — an :ok summary passes the job" do
    stub(Billing, :sweep_auto_recharge, fn -> {:ok, %{reminded: 1, recovered: 0}} end)

    assert :ok = RechargeSweep.perform(%Oban.Job{})
  end

  test "a failed pass fails the job so Oban retries" do
    stub(Billing, :sweep_auto_recharge, fn ->
      {:error, "auto-recharge reminder sweep failed for 1 org(s)"}
    end)

    assert {:error, "auto-recharge reminder sweep failed for 1 org(s)"} =
             RechargeSweep.perform(%Oban.Job{})
  end
end

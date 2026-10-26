defmodule FluxVale.Infrastructure.AccessGateway.PerformSettleTest do
  @moduledoc false

  # ADR-0039 §5's accrual: gateway-existence billing on the instance
  # settle discipline — advisory wallet lock, prorated micro-cents over
  # the Gregorian month, keyless debit, anchor advance in one
  # transaction. :active is the only accrual arm.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  @month_seconds 2_629_746
  @monthly_cents 200

  setup do
    stub(Tailscale, :provision_gateway, fn _gateway, _key -> {:ok, :provisioned} end)
    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)
    :ok
  end

  describe "settle" do
    test "prorates the monthly rate over the open interval" do
      {org, _owner, _wallet} = wallet!(10_000)
      gateway = AccessFixtures.gateway!(org, monthly_cents: @monthly_cents)

      # One full Gregorian month of open interval bills exactly the
      # monthly rate (the constant settle and the runway share).
      pin_metering_since!(gateway, ago(@month_seconds))

      assert {:ok, settled} = settle(gateway)

      # due = 200¢ × 10_000 µ¢ × 2_629_746s / 2_629_746s = 2_000_000 µ¢
      assert ledger_total(settled.organization_id) == -@monthly_cents
      # The anchor advanced to (about) now.
      assert DateTime.diff(DateTime.utc_now(), settled.metering_since, :second) < 5
    end

    test "a sub-cent interval accrues into the wallet carryover, no ledger row" do
      {org, _owner, _wallet} = wallet!(10_000)
      gateway = AccessFixtures.gateway!(org, monthly_cents: @monthly_cents)

      # One hour at 200¢/mo ≈ 2_737 µ¢ — a real fraction, well under a
      # cent, so the pool moves and the ledger stays silent.
      pin_metering_since!(gateway, ago(3600))

      assert {:ok, settled} = settle(gateway)

      assert ledger_total(settled.organization_id) == 0
      # The fraction is banked, not dropped (the no-dust rule).
      assert settled_wallet(settled.organization_id).carryover > 0
    end

    test "a tick that prorates to zero posts nothing and still advances" do
      {org, _owner, _wallet} = wallet!(10_000)
      gateway = AccessFixtures.gateway!(org, monthly_cents: @monthly_cents)

      # A 1-second gap at 200¢/mo floors to 0 µ¢ (the integer prorate).
      pin_metering_since!(gateway, ago(1))

      assert {:ok, settled} = settle(gateway)

      assert ledger_total(settled.organization_id) == 0
      assert DateTime.diff(DateTime.utc_now(), settled.metering_since, :second) < 5
    end

    test "a fresh gateway arms the anchor without billing from the epoch" do
      {org, _owner, _wallet} = wallet!(10_000)
      gateway = AccessFixtures.gateway!(org)

      # gateway! lands :active with an anchor; clear it to stage the
      # first-tick shape.
      cleared =
        gateway
        |> Ash.Changeset.for_update(:settle_anchors, %{metering_since: nil}, authorize?: false)
        |> Ash.update!()

      assert {:ok, settled} = settle(cleared)

      assert ledger_total(settled.organization_id) == 0
      assert settled.metering_since
    end

    # The must-fix's other half: an un-reachable gateway must not bill.
    test "a suspended gateway accrues nothing" do
      {org, _owner, _wallet} = wallet!(10_000)
      gateway = AccessFixtures.gateway!(org, state: :suspended)
      pin_metering_since!(gateway, ago(@month_seconds))

      assert {:ok, settled} = settle(gateway)

      assert ledger_total(settled.organization_id) == 0
    end

    test "a needs_attention gateway accrues nothing" do
      {org, _owner, _wallet} = wallet!(10_000)
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)
      pin_metering_since!(gateway, ago(@month_seconds))

      assert {:ok, settled} = settle(gateway)

      assert ledger_total(settled.organization_id) == 0
    end

    test "the ledger row carries the gateway's subject attribution" do
      {org, _owner, _wallet} = wallet!(10_000)
      gateway = AccessFixtures.gateway!(org, monthly_cents: @monthly_cents)
      pin_metering_since!(gateway, ago(@month_seconds))

      assert {:ok, _settled} = settle(gateway)

      entry = latest_entry(org.id)

      assert entry.reason == :usage
      assert entry.type == :debit
      assert entry.subject == "access-gateway:#{gateway.id}"
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp wallet!(balance_cents) do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)

    if balance_cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, balance_cents, reason: :adjustment)
    end

    {org, owner, wallet}
  end

  defp settle(gateway) do
    gateway
    |> Ash.Changeset.for_update(:perform_settle, %{}, authorize?: false)
    |> Ash.update()
  end

  # Settlement's cursor is not on any accept list (it is the operation's
  # own write); staging it here uses the system action that owns it.
  defp pin_metering_since!(gateway, at) do
    gateway
    |> Ash.Changeset.for_update(:settle_anchors, %{metering_since: at}, authorize?: false)
    |> Ash.update!()
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  # Only this gateway's postings — the wallet's opening grant is not
  # what these tests are about (the instance settle tests' stance).
  defp ledger_total(organization_id) do
    organization_id
    |> entries()
    |> Enum.filter(&gateway_entry?/1)
    |> Enum.map(& &1.amount)
    |> Enum.sum()
  end

  defp latest_entry(organization_id) do
    organization_id
    |> entries()
    |> Enum.find(&gateway_entry?/1)
  end

  defp entries(organization_id) do
    wallet = settled_wallet(organization_id)

    LedgerEntry
    |> Ash.Query.filter(wallet_id == ^wallet.id)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  # Nil-safe: the opening grant and every instance posting carry no
  # subject (additive column, ADR-0039 §5).
  defp gateway_entry?(%LedgerEntry{subject: subject}) when is_binary(subject),
    do: String.starts_with?(subject, "access-gateway:")

  defp gateway_entry?(_entry), do: false

  defp settled_wallet(organization_id) do
    {:ok, wallet} = Billing.ensure_wallet(%FluxVale.Accounts.Organization{id: organization_id})
    Ash.get!(FluxVale.Billing.Wallet, wallet.id, authorize?: false)
  end
end

defmodule FluxVale.Workers.AccessDomainSettle do
  @moduledoc """
  The S6 accrual tick (ADR-0040 §11): every 15 minutes, settle every
  serving custom domain — the gateway settle trigger's cadence and
  queue, as a walking worker (the janitor shape) because the settle is
  a per-row Ash action with its own wallet lock; AshOban's per-row
  scheduler would enqueue one job per domain for the same outcome.

  The worker's query is the suggestion (`:custom` rows in the serving
  arms — `:verified` and `:needs_attention` both SERVE; `:pending`,
  `:failed` and `:suspended` never accrue); `PerformSettle`'s fresh
  `FOR UPDATE` re-check against the committed row is the rule. A
  domain whose settle crashes is logged and skipped — one bad wallet
  must not eat the fleet's accrual — and the job still fails so Oban
  retries the tick.
  """

  use Oban.Worker, queue: :settler, max_attempts: 3

  alias FluxVale.Infrastructure.AccessDomain

  require Ash.Query
  require Logger

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(_job) do
    domains = accruing_domains()
    failed = Enum.flat_map(domains, &safe_settle/1)

    case failed do
      [] -> :ok
      failures -> {:error, "access-domain settle failed for #{length(failures)} domain(s)"}
    end
  end

  # The serving arms: `:verified` and `:needs_attention` (both SERVE —
  # see PerformSettle). The accrual arms are the billing switch, so
  # the scheduler never wakes a row that must not bill.
  defp accruing_domains do
    AccessDomain
    |> Ash.Query.filter(kind == :custom and state in [:verified, :needs_attention])
    |> Ash.read!(authorize?: false)
  end

  # A crash in one domain's settle must not eat the rest of the tick.
  defp safe_settle(domain) do
    case AccessDomain.perform_settle(domain, authorize?: false) do
      {:ok, _settled} ->
        []

      {:error, reason} ->
        Logger.error("Access domain #{domain.domain} settle failed: #{inspect(reason)}")

        [domain.id]
    end
  rescue
    exception ->
      Logger.error("Access domain #{domain.domain} settle crashed: #{inspect(exception)}")

      [domain.id]
  end
end

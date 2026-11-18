defmodule FluxVale.Infrastructure.AccessProviders.Tailscale.TokenCache do
  @moduledoc """
  The OAuth-derived access token's cache (#836 lane B): one
  client-credentials exchange per client per hour in the single-
  threaded case, not one per API call — two CONCURRENT first-fetches
  may both exchange (both tokens are freshly minted and valid; last
  write wins, harmlessly — no serialization, by design). Keyed by
  `client_id`, value `%{token: String.t(), expires_at:
  DateTime.t()}`; a fetch inside the last
  `@refresh_skew_seconds` (300s — the clock-skew window) of its life
  exchanges fresh, and `invalidate/1` erases ahead of the wrapper's
  retry-once on a 401.

  **Custody** (the addendum's ruling, stated): the cached access token
  lives here for at most its 1h life — within lane A's "memory +
  Secret" line (memory includes this cache). The table is `:protected`
  (this process owns it; writes go through it, reads are direct), an
  entry is erased on invalidation and on expiry, and the token is
  never inspected into a log — memory only, like the minted key. The
  client SECRET is never stored: it rides no entry. Exchange failures
  cache nothing.

  The exchange runs in the CALLER's process (Mimic stubs are
  process-local — the StorageExpansion stance); this process only owns
  the table.
  """

  use GenServer

  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient

  @table __MODULE__.Cache

  # The skew window: a token within 300s of its expiry is refreshed
  # instead of used (the addendum's proactive-refresh ruling).
  @refresh_skew_seconds 300

  @doc """
  The client's access token — from the cache while fresh, else a fresh
  exchange (cached on success). Exchange failure propagates; nothing
  is cached. `now` is injectable so tests can walk the clock.
  """
  @spec fetch(String.t(), String.t(), DateTime.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch(client_id, client_secret, now \\ DateTime.utc_now()) do
    case lookup(client_id, now) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        exchange(client_id, client_secret, now)
    end
  end

  # Reads are direct (the :protected table allows them from any
  # process); the freshness line is `now < expires_at − skew`, and a
  # stale entry is erased on the spot (custody: erased on expiry).
  defp lookup(client_id, now) do
    case :ets.lookup(@table, client_id) do
      [{^client_id, %{token: token, expires_at: expires_at}}] ->
        threshold = DateTime.add(expires_at, -@refresh_skew_seconds, :second)

        if DateTime.compare(now, threshold) == :lt do
          {:ok, token}
        else
          invalidate(client_id)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    # coveralls-ignore-start - the owner-dies-mid-call window is a
    # scheduler race no sequential test can stage (a deleted table
    # already fails the lookup); degrading to a fresh exchange keeps
    # the API path alive across a supervisor restart.
    ArgumentError ->
      :miss
      # coveralls-ignore-stop
  end

  defp exchange(client_id, client_secret, now) do
    case ApiClient.oauth_exchange(client_id, client_secret) do
      {:ok, %{access_token: token, expires_in: seconds}} ->
        cache(client_id, token, DateTime.add(now, seconds, :second))
        {:ok, token}

      # Failures cache nothing — a broken exchange must not stick.
      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Erases the client's entry — the wrapper's call on a 401, ahead of
  its one retry (the re-fetch then exchanges fresh).
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(client_id) do
    GenServer.call(__MODULE__, {:delete, client_id})
  rescue
    # coveralls-ignore-start - an empty (owner-restarting) table needs
    # no invalidation; the next fetch exchanges fresh either way.
    ArgumentError ->
      :ok
      # coveralls-ignore-stop
  catch
    # coveralls-ignore-start - a DEAD owner exits {:noproc, …} rather
    # than raising — rescue cannot catch an exit class (#863 review:
    # the degradation contract was false as written). Same answer:
    # nothing to invalidate.
    :exit, _noproc ->
      :ok
      # coveralls-ignore-stop
  end

  # Writes go through the owner (:protected). A lost write (restart
  # window) only costs one extra exchange on the next fetch.
  defp cache(client_id, token, expires_at) do
    GenServer.call(__MODULE__, {:put, client_id, token, expires_at})
  rescue
    # coveralls-ignore-start - the owner-restart window again: the
    # token itself is good; only the caching is lost.
    ArgumentError ->
      :ok
      # coveralls-ignore-stop
  catch
    # coveralls-ignore-start - the exit-class twin of the rescue
    # above (#863 review): a dead owner must degrade, not crash the
    # API caller mid-flight.
    :exit, _noproc ->
      :ok
      # coveralls-ignore-stop
  end

  # Test support: the table lives under the app tree for the whole
  # run, so tests that seed it clear it between tests (the token must
  # not leak across tests). Fails loudly if the table is gone — there
  # is no honest prod caller, and silence would mask breakage.
  @doc false
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # The owner process's only job: hold the ETS table (a dying owner
  # drops the cache; the next fetch re-exchanges — no state to recover).
  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, client_id, token, expires_at}, _from, state) do
    :ets.insert(@table, {client_id, %{token: token, expires_at: expires_at}})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:delete, client_id}, _from, state) do
    :ets.delete(@table, client_id)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
